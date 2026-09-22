#!/bin/bash
# Don't Starve Together dedicated server: one container, one bash supervisor, one or two shards.
#
#   1. PUID/PGID remap of the `dst` user (its home is re-owned; the game tree and /data never are).
#   2. UPDATE_ON_START: DepotDownloader re-validates the game files in /app against Steam's current build.
#   3. First start on an empty /data: Cluster_1 (cluster.ini, Master/server.ini, and with CAVES=true
#      Caves/server.ini + Caves/worldgenoverride.lua) is generated from the environment. An existing
#      cluster is never modified, and cluster_password is never read, written or logged by this script.
#   4. The Klei cluster token from CLUSTER_TOKEN_FILE or CLUSTER_TOKEN goes to Cluster_1/cluster_token.txt
#      (0600) and is redacted from the container log.
#   5. Master, then Caves, are launched with their stdin on a FIFO each (the Lua console) and their output
#      through one redactor. `docker stop` types c_shutdown(true) into each console, Caves first, so the
#      worlds are saved; STOP_TIMEOUT_SECONDS later any shard still running gets SIGTERM.
#   6. If a shard dies on its own the other one is shut down and the container exits non-zero.
set -euo pipefail

APP_DIR="/app"
BIN_DIR="${APP_DIR}/bin64"
SERVER_BIN="dontstarve_dedicated_server_nullrenderer_x64"
APP_ID="343050"
DEPOTDOWNLOADER_BIN="/opt/depotdownloader/DepotDownloader"
DEPOT_FILELIST="/tmp/dst-depot-filelist"
# The same rule the Dockerfile's game stage uses: everything except bin/ (the 32-bit server, never run).
DEPOT_FILELIST_RULE='regex:^(?!bin/).*$'
# "<depot> <manifest>" per line: the depot manifests installed in APP_DIR, written by the image build and
# after every successful download here; the auto-update check compares it with what Steam serves now.
INSTALLED_MANIFESTS_FILE="${APP_DIR}/.dst-manifests"

DATA_ROOT="/data"
CONF_DIR="DoNotStarveTogether"
CLUSTER="Cluster_1"
CLUSTER_DIR="${DATA_ROOT}/${CONF_DIR}/${CLUSTER}"
TOKEN_FILE="${CLUSTER_DIR}/cluster_token.txt"

RUN_USER="${CONTAINER_USER:-dst}"
RUN_GROUP="${CONTAINER_GROUP:-dst}"
RUN_HOME="/home/${RUN_USER}"
OUTPUT_FIFO="/tmp/dst-output"
AUTO_UPDATE_FLAG_FILE="/tmp/dst-auto-update"
STOP_TIMEOUT_SECONDS="${STOP_TIMEOUT_SECONDS:-240}"

SHARDS=()
declare -A SHARD_PID=() CONSOLE_FD=() SHARD_RC=()
REDACTOR_PID=""
AUTO_UPDATE_MONITOR_PID=""
STOP_TIMER_PID=""
STOP_REQUESTED=0
FORCE_KILLED=0
RESOLVED_TOKEN=""

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_root()   { [[ "$(id -u)" -eq 0 ]]; }
is_true()   { local v; v="$(lowercase "${1:-}")"; [[ "${v}" == "true" || "${v}" == "1" || "${v}" == "yes" ]]; }
log()       { printf '[entrypoint] %s\n' "$*"; }
die()       { printf '[entrypoint] %s\n' "$*" >&2; exit 1; }

run_as_user() {
    if is_root; then
        # gosu leaves an already-set HOME alone and the image sets HOME=/root; pin it to the run user.
        gosu "${RUN_USER}" env HOME="${RUN_HOME}" "$@"
    else
        "$@"
    fi
}

# --- Identity -------------------------------------------------------------------------------------------
# PUID/PGID: the shards run as uid PUID with primary gid PGID, so everything they create under /data carries
# those ids. The 4 GB game tree in /app stays owned by the image's dst:dst (1000:1000): re-owning it on every
# container start would copy all of it up into the container layer (overlayfs copies a file up on chown), so
# the tree is group-writable instead and the run user keeps gid 1000 as a supplementary group. gosu <user>
# (no explicit group) applies the supplementary groups from /etc/group. /data is never re-owned.
adjust_permissions() {
    is_root || return 0
    local target_gid="${PGID:-${CONTAINER_GID}}" target_uid="${PUID:-${CONTAINER_UID}}" current_gid current_uid group
    current_gid="$(id -g "${RUN_USER}")"
    if [[ -n "${target_gid}" && "${target_gid}" != "${current_gid}" ]]; then
        group="$(getent group "${target_gid}" | cut -d: -f1 || true)"
        if [[ -z "${group}" ]]; then
            group="${RUN_GROUP}run"
            groupadd -g "${target_gid}" "${group}"
        fi
        usermod -g "${group}" -aG "${RUN_GROUP}" "${RUN_USER}"
    fi
    current_uid="$(id -u "${RUN_USER}")"
    if [[ -n "${target_uid}" && "${target_uid}" != "${current_uid}" ]]; then
        usermod -o -u "${target_uid}" "${RUN_USER}"
    fi
    chown -R "${RUN_USER}:$(id -gn "${RUN_USER}")" "${RUN_HOME}"
    log "Running as ${RUN_USER} ($(id -u "${RUN_USER}"):$(id -g "${RUN_USER}"), groups $(id -G "${RUN_USER}" | tr ' ' ','))."
}

check_data_dir() {
    [[ -d "${DATA_ROOT}" ]] || die "${DATA_ROOT} does not exist; mount the data directory there."
    if ! run_as_user test -w "${DATA_ROOT}"; then
        die "${DATA_ROOT} is not writable by ${RUN_USER} (uid $(id -u "${RUN_USER}")). This image never changes the ownership of the data directory; chown it on the host to PUID:PGID, or set PUID/PGID to its owner."
    fi
}

# --- Settings --------------------------------------------------------------------------------------------
validate_env() {
    case "${MAX_PLAYERS}" in
        ''|*[!0-9]*) die "MAX_PLAYERS must be a number from 1 to 64 (got '${MAX_PLAYERS}')." ;;
    esac
    (( MAX_PLAYERS >= 1 && MAX_PLAYERS <= 64 )) || die "MAX_PLAYERS must be from 1 to 64 (got ${MAX_PLAYERS})."
    GAME_MODE="$(lowercase "${GAME_MODE}")"
    case "${GAME_MODE}" in
        survival|endless|wilderness) ;;
        *) die "GAME_MODE must be survival, endless or wilderness (got '${GAME_MODE}')." ;;
    esac
    CLUSTER_INTENTION="$(lowercase "${CLUSTER_INTENTION}")"
    case "${CLUSTER_INTENTION}" in
        cooperative|competitive|social|madness) ;;
        *) die "CLUSTER_INTENTION must be cooperative, competitive, social or madness (got '${CLUSTER_INTENTION}')." ;;
    esac
    case "${STOP_TIMEOUT_SECONDS}" in
        ''|*[!0-9]*) die "STOP_TIMEOUT_SECONDS must be a number of seconds (got '${STOP_TIMEOUT_SECONDS}')." ;;
    esac
    local v
    for v in PVP PAUSE_WHEN_EMPTY OFFLINE_CLUSTER CAVES UPDATE_ON_START; do
        if is_true "${!v}"; then printf -v "${v}" 'true'; else printf -v "${v}" 'false'; fi
    done
    if [[ -z "${CLUSTER_NAME}" ]]; then
        CLUSTER_NAME="Don't Starve Together"
    fi
    SHARDS=(Master)
    if [[ "${CAVES}" == "true" ]]; then
        SHARDS+=(Caves)
    fi
}

# Write a file as the run user, atomically, with the given mode. Content on stdin.
install_file() {
    local dest="$1" mode="$2" tmp
    tmp="$(mktemp "${dest}.tmp.XXXXXX")"
    cat > "${tmp}"
    chmod "${mode}" "${tmp}"
    if is_root; then
        chown "${RUN_USER}:$(id -gn "${RUN_USER}")" "${tmp}"
    fi
    mv -f "${tmp}" "${dest}"
}

make_dir() {
    if [[ -d "$1" ]]; then
        return
    fi
    mkdir -p "$1"
    if is_root; then
        chown "${RUN_USER}:$(id -gn "${RUN_USER}")" "$1"
    fi
}

# First start only: no cluster.ini under /data means nothing has been configured yet. Keys and defaults per
# Klei's "Dedicated Server Settings Guide" (cluster.ini [GAMEPLAY]/[NETWORK]/[MISC]/[SHARD], server.ini
# [NETWORK]/[SHARD]/[STEAM]). cluster_password is deliberately absent: Klei reads "omit it for no
# password", and adding one is the operator's edit of cluster.ini, never this script's.
generate_cluster() {
    if [[ -f "${CLUSTER_DIR}/cluster.ini" ]]; then
        log "Using the existing cluster at ${CLUSTER_DIR} (cluster.ini present; nothing is generated or modified)."
        local shard
        for shard in "${SHARDS[@]}"; do
            [[ -f "${CLUSTER_DIR}/${shard}/server.ini" ]] \
                || die "${CLUSTER_DIR}/${shard}/server.ini is missing but the ${shard} shard is enabled$( [[ "${shard}" == Caves ]] && printf ' (CAVES=true)' ). This image does not modify an existing cluster; create the shard directory yourself, or set CAVES=false."
        done
        return
    fi

    log "No cluster at ${CLUSTER_DIR}; generating ${CLUSTER} from the environment (CLUSTER_NAME='${CLUSTER_NAME}', MAX_PLAYERS=${MAX_PLAYERS}, GAME_MODE=${GAME_MODE}, PVP=${PVP}, PAUSE_WHEN_EMPTY=${PAUSE_WHEN_EMPTY}, CAVES=${CAVES}, OFFLINE_CLUSTER=${OFFLINE_CLUSTER})."
    make_dir "${DATA_ROOT}/${CONF_DIR}"
    make_dir "${CLUSTER_DIR}"
    make_dir "${CLUSTER_DIR}/Master"

    local cluster_key=""
    if [[ "${CAVES}" == "true" ]]; then
        cluster_key="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        make_dir "${CLUSTER_DIR}/Caves"
    fi

    {
        printf '[GAMEPLAY]\ngame_mode = %s\nmax_players = %s\npvp = %s\npause_when_empty = %s\n\n' \
            "${GAME_MODE}" "${MAX_PLAYERS}" "${PVP}" "${PAUSE_WHEN_EMPTY}"
        printf '[NETWORK]\ncluster_name = %s\ncluster_description = %s\ncluster_intention = %s\noffline_cluster = %s\n\n' \
            "${CLUSTER_NAME}" "${CLUSTER_DESCRIPTION}" "${CLUSTER_INTENTION}" "${OFFLINE_CLUSTER}"
        printf '[MISC]\nconsole_enabled = true\n'
        if [[ "${CAVES}" == "true" ]]; then
            printf '\n[SHARD]\nshard_enabled = true\nbind_ip = 127.0.0.1\nmaster_ip = 127.0.0.1\nmaster_port = 10888\ncluster_key = %s\n' "${cluster_key}"
        fi
    } | install_file "${CLUSTER_DIR}/cluster.ini" 644

    # Master: players on 10999; Steam master-server/authentication ports 12346/12347 (the ones the
    # container publishes). Caves: players on 11000; its Steam ports only have to differ from Master's on
    # the same machine (Klei), they are not published.
    printf '[NETWORK]\nserver_port = 10999\n\n[SHARD]\nis_master = true\n\n[STEAM]\nmaster_server_port = 12346\nauthentication_port = 12347\n' \
        | install_file "${CLUSTER_DIR}/Master/server.ini" 644

    if [[ "${CAVES}" == "true" ]]; then
        printf '[NETWORK]\nserver_port = 11000\n\n[SHARD]\nis_master = false\nname = Caves\n\n[STEAM]\nmaster_server_port = 12348\nauthentication_port = 12349\n' \
            | install_file "${CLUSTER_DIR}/Caves/server.ini" 644
        printf 'return {\n  override_enabled = true,\n  preset = "DST_CAVE",\n}\n' \
            | install_file "${CLUSTER_DIR}/Caves/worldgenoverride.lua" 644
    fi
    log "Generated ${CLUSTER_DIR}/cluster.ini, Master/server.ini$( [[ "${CAVES}" == "true" ]] && printf ', Caves/server.ini, Caves/worldgenoverride.lua' )."
}

# Whether the cluster that will actually run is offline (its cluster.ini decides, not the environment,
# because the file may predate this container).
cluster_is_offline() {
    grep -Eiq '^[[:space:]]*offline_cluster[[:space:]]*=[[:space:]]*true' "${CLUSTER_DIR}/cluster.ini"
}

# --- Klei cluster token -----------------------------------------------------------------------------------
# CLUSTER_TOKEN_FILE (a Docker secret, say) wins over CLUSTER_TOKEN. With neither set, a token already in
# cluster_token.txt is used as it is. Whatever the source, the value is only ever handled here: written
# 0600, handed to the redactor through its environment, dropped from the shards' environment, never printed.
resolve_token() {
    if [[ -n "${CLUSTER_TOKEN_FILE:-}" ]]; then
        [[ -r "${CLUSTER_TOKEN_FILE}" ]] || die "CLUSTER_TOKEN_FILE is set to '${CLUSTER_TOKEN_FILE}' but that file does not exist or is not readable."
        RESOLVED_TOKEN="$(head -n 1 "${CLUSTER_TOKEN_FILE}")"
        [[ -n "${RESOLVED_TOKEN}" ]] || die "CLUSTER_TOKEN_FILE '${CLUSTER_TOKEN_FILE}' is empty."
        log "Cluster token: read from CLUSTER_TOKEN_FILE."
    elif [[ -n "${CLUSTER_TOKEN:-}" ]]; then
        RESOLVED_TOKEN="${CLUSTER_TOKEN}"
        log "Cluster token: read from CLUSTER_TOKEN."
    fi

    if [[ -n "${RESOLVED_TOKEN}" ]]; then
        printf '%s\n' "${RESOLVED_TOKEN}" | install_file "${TOKEN_FILE}" 600
        log "Cluster token: written to ${TOKEN_FILE} (0600, $(wc -c < "${TOKEN_FILE}") bytes)."
    elif [[ -s "${TOKEN_FILE}" ]]; then
        RESOLVED_TOKEN="$(head -n 1 "${TOKEN_FILE}")"
        log "Cluster token: using the existing ${TOKEN_FILE} ($(wc -c < "${TOKEN_FILE}") bytes)."
    fi

    if [[ -z "${RESOLVED_TOKEN}" ]]; then
        if cluster_is_offline; then
            log "Cluster token: none (offline cluster; not needed)."
        else
            die "No cluster token: cluster.ini says offline_cluster is not true, and neither CLUSTER_TOKEN_FILE nor CLUSTER_TOKEN is set nor is ${TOKEN_FILE} non-empty. An online cluster refuses to start without one. Generate a token in the game (Account -> Games -> Don't Starve Together Servers -> Add New Server) and pass it, or set OFFLINE_CLUSTER=true before the first start."
        fi
    fi
    unset CLUSTER_TOKEN
}

# --- Game files: DepotDownloader ---------------------------------------------------------------------------
manifests_from_log() {
    sed -n -e 's/^Got manifest request code for depot \([0-9]*\) from app [0-9]*, manifest \([0-9]*\),.*/\1 \2/p' \
           -e 's/^Already have manifest \([0-9]*\) for depot \([0-9]*\)\..*/\2 \1/p' "$1" | sort -u
}

manifests_line() { printf '%s\n' "$1" | tr ' ' ':' | tr '\n' ' ' | sed 's/ $//'; }

installed_manifests() {
    [[ -f "${INSTALLED_MANIFESTS_FILE}" ]] && sort -u "${INSTALLED_MANIFESTS_FILE}" || true
}

# What Steam serves right now: a -manifest-only run into a scratch directory (a few hundred KB, no game files).
remote_manifests() {
    local scratch="/tmp/dst-manifest-check" log="/tmp/dst-manifest-check.log"
    rm -rf "${scratch}" "${log}"
    if ! run_as_user "${DEPOTDOWNLOADER_BIN}" -app "${APP_ID}" -os linux -osarch 64 -manifest-only -dir "${scratch}" >"${log}" 2>&1; then
        rm -rf "${scratch}" "${log}"
        return 1
    fi
    manifests_from_log "${log}"
    rm -rf "${scratch}" "${log}"
}

record_installed_manifests() {
    local found
    found="$(manifests_from_log "$1")"
    if [[ -z "${found}" ]]; then
        log "WARN: could not read the depot manifests from DepotDownloader's output; the auto-update baseline is left as it was." >&2
        return
    fi
    printf '%s\n' "${found}" | install_file "${INSTALLED_MANIFESTS_FILE}" 644
}

maybe_update_server() {
    local update="${UPDATE_ON_START}"
    [[ -f "${AUTO_UPDATE_FLAG_FILE}" ]] && update=true
    if [[ -x "${BIN_DIR}/${SERVER_BIN}" && "${update}" != "true" ]]; then
        log "UPDATE_ON_START=false; running build $(cat "${APP_DIR}/version.txt" 2>/dev/null || echo unknown) as baked into the image."
        return
    fi

    log "DepotDownloader: validating the server files against Steam's current build (anonymous, app ${APP_ID})..."
    printf '%s\n' "${DEPOT_FILELIST_RULE}" > "${DEPOT_FILELIST}"
    chmod 644 "${DEPOT_FILELIST}"
    local logfile="/tmp/dst-update.log" started result
    started="$(date +%s)"
    set +e
    run_as_user "${DEPOTDOWNLOADER_BIN}" -app "${APP_ID}" -os linux -osarch 64 -dir "${APP_DIR}" \
        -filelist "${DEPOT_FILELIST}" -validate 2>&1 | tee "${logfile}"
    result="${PIPESTATUS[0]}"
    set -e
    if [[ "${result}" -eq 0 ]] && grep -q '^Total downloaded: ' "${logfile}" && [[ -f "${BIN_DIR}/${SERVER_BIN}" ]]; then
        record_installed_manifests "${logfile}"
        rm -f "${logfile}"
        # DepotDownloader carries no Unix mode bits; the freshly written binary must be executable again.
        chmod 755 "${BIN_DIR}/${SERVER_BIN}"
        find "${APP_DIR}/bin" -depth -type d -empty -delete 2>/dev/null || true
        log "DepotDownloader: done in $(( $(date +%s) - started ))s; build $(cat "${APP_DIR}/version.txt"), manifests $(manifests_line "$(installed_manifests)")."
    else
        rm -f "${logfile}"
        [[ "${result}" -ne 0 ]] || result=1
        if [[ -x "${BIN_DIR}/${SERVER_BIN}" ]]; then
            log "WARN: DepotDownloader did not complete (exit ${result}); keeping the server build already in place." >&2
        else
            die "DepotDownloader failed (exit ${result}) and there is no server binary to fall back to."
        fi
    fi
    rm -f "${AUTO_UPDATE_FLAG_FILE}"
}

# --- Auto-update ---------------------------------------------------------------------------------------------
check_for_remote_update() {
    local current remote
    current="$(installed_manifests)"
    remote="$(remote_manifests || true)"
    if [[ -z "${remote}" ]]; then
        log "Auto-update: unable to determine the remote build (DepotDownloader manifest check failed)." >&2
        return 1
    fi
    if [[ -z "${current}" ]]; then
        log "Auto-update: no local build record; treating as update required."
        return 0
    fi
    if [[ "${remote}" != "${current}" ]]; then
        log "Auto-update: new build detected (local $(manifests_line "${current}"), remote $(manifests_line "${remote}"))."
        return 0
    fi
    return 1
}

start_auto_update_monitor() {
    local minutes="${AUTO_UPDATE_INTERVAL_MINUTES:-0}"
    case "${minutes}" in
        ''|*[!0-9]*) log "WARN: AUTO_UPDATE_INTERVAL_MINUTES must be numeric; auto-update disabled." >&2; return ;;
    esac
    (( minutes > 0 )) || return 0
    log "Auto-update: enabled; checking for new builds every ${minutes} minute(s)."
    (
        close_inherited_fds
        while true; do
            sleep "$(( minutes * 60 ))"
            if check_for_remote_update; then
                touch "${AUTO_UPDATE_FLAG_FILE}"
                log "Auto-update: stopping the shards to apply the new build."
                kill -USR1 $$
                exit 0
            fi
        done
    ) &
    AUTO_UPDATE_MONITOR_PID=$!
}

stop_auto_update_monitor() {
    if [[ -n "${AUTO_UPDATE_MONITOR_PID}" ]]; then
        kill "${AUTO_UPDATE_MONITOR_PID}" 2>/dev/null || true
        wait "${AUTO_UPDATE_MONITOR_PID}" 2>/dev/null || true
        AUTO_UPDATE_MONITOR_PID=""
    fi
}

# --- Consoles and output -----------------------------------------------------------------------------------------
# One redactor for the container's lifetime; fd 4 keeps the FIFO open read-write so the reader survives shard
# restarts and only sees EOF once close_output drops fd 4 after the last shard has exited.
open_output() {
    rm -f "${OUTPUT_FIFO}"
    mkfifo -m 600 "${OUTPUT_FIFO}"
    exec 4<>"${OUTPUT_FIFO}"
    DST_REDACT_SECRET="${RESOLVED_TOKEN}" bash "${APP_DIR}/redact.sh" <"${OUTPUT_FIFO}" 4>&- &   # no consoles exist yet
    REDACTOR_PID=$!
}

close_output() {
    exec 4>&-
    if [[ -n "${REDACTOR_PID}" ]]; then
        wait "${REDACTOR_PID}" 2>/dev/null || true
        REDACTOR_PID=""
    fi
}

# Each shard's stdin is a FIFO. This script holds it open read-write (so the shard's read-only open never
# blocks and it sees no EOF while running); with console_enabled (cluster.ini [MISC], the default) the server
# reads Lua from it. After c_shutdown the descriptor is closed: the server's stdin thread ("StreamInput")
# blocks in read() and the process does not exit until that read returns EOF, so an always-open console
# would leave a saved, fully shut-down shard hanging forever (observed 2026-09-22). The descriptor number is
# chosen by bash.
open_console() {
    local shard="$1" fifo="/tmp/dst-console-$1" fd
    rm -f "${fifo}"
    mkfifo -m 600 "${fifo}"
    exec {fd}<>"${fifo}"
    CONSOLE_FD["${shard}"]="${fd}"
}

close_console() {
    local shard="$1" fd="${CONSOLE_FD[$1]:-}"
    if [[ -n "${fd}" ]]; then
        exec {fd}>&-
        unset "CONSOLE_FD[${shard}]"
    fi
}

send_console() {
    local fd="${CONSOLE_FD[$1]}"
    printf '%s\n' "$2" >&"${fd}"
}

# Every background child must drop the console descriptors it inherited: a shard exits only when its stdin
# FIFO has no writer left, and a stray copy held by the redactor, a prefixer, the auto-update monitor or the
# stop timer would keep a saved, shut-down shard hanging forever. Also drops fd 4 (the output FIFO's spare
# end) so the redactor sees EOF at the end. Call first thing inside a `( ... ) &` body.
close_inherited_fds() {
    local fd
    for fd in "${CONSOLE_FD[@]}"; do
        eval "exec ${fd}>&-"
    done
    exec 4>&-
}

shard_alive() {
    [[ -n "${SHARD_PID[$1]:-}" ]] && kill -0 "${SHARD_PID[$1]}" 2>/dev/null
}

# --- Shards ------------------------------------------------------------------------------------------------------
launch_shard() {
    local shard="$1" raw="/tmp/dst-raw-$1"
    open_console "${shard}"
    rm -f "${raw}"
    mkfifo -m 600 "${raw}"
    # Prefixer: tags every line of this shard's output with its name on the way into the shared redactor.
    (
        close_inherited_fds
        while IFS= read -r line || [[ -n "${line}" ]]; do
            printf '[%s] %s\n' "${shard}" "${line}"
        done < "${raw}"
    ) > "${OUTPUT_FIFO}" &

    log "Starting shard ${shard}: ${SERVER_BIN} -persistent_storage_root ${DATA_ROOT} -conf_dir ${CONF_DIR} -cluster ${CLUSTER} -shard ${shard}"
    # The server must run from bin64/ (its rpath is ./lib64 and it finds ../data from there). The token is
    # dropped from its environment; the console FIFO, opened read-only, is its stdin; stdout/stderr go to
    # the prefixer.
    (
        close_inherited_fds
        cd "${BIN_DIR}"
        umask 022
        # SteamAppId/SteamGameId as Klei's own launch_dedicated_server.sh exports them.
        if is_root; then
            exec gosu "${RUN_USER}" env -u CLUSTER_TOKEN -u CLUSTER_TOKEN_FILE HOME="${RUN_HOME}" SteamAppId=322330 SteamGameId=322330 \
                "./${SERVER_BIN}" -persistent_storage_root "${DATA_ROOT}" -conf_dir "${CONF_DIR}" -cluster "${CLUSTER}" -shard "${shard}"
        else
            exec env -u CLUSTER_TOKEN -u CLUSTER_TOKEN_FILE SteamAppId=322330 SteamGameId=322330 \
                "./${SERVER_BIN}" -persistent_storage_root "${DATA_ROOT}" -conf_dir "${CONF_DIR}" -cluster "${CLUSTER}" -shard "${shard}"
        fi
    ) <"/tmp/dst-console-${shard}" >"${raw}" 2>&1 &
    SHARD_PID["${shard}"]=$!
}

launch_shards() {
    local shard
    for shard in "${SHARDS[@]}"; do
        launch_shard "${shard}"
        # Caves connects to Master's shard port; give Master a head start so the first attempt lands.
        if [[ "${shard}" == "Master" && "${#SHARDS[@]}" -gt 1 ]]; then
            sleep 5
        fi
    done
}

# Ask every running shard to save and exit through its console, secondary shards first. STOP_TIMEOUT_SECONDS
# later anything still running is sent SIGTERM (which, for this server, means an unsaved exit).
request_stop_all() {
    (( STOP_REQUESTED )) && return 0
    STOP_REQUESTED=1
    local shard
    for (( i = ${#SHARDS[@]} - 1; i >= 0; i-- )); do
        shard="${SHARDS[$i]}"
        if shard_alive "${shard}"; then
            log "Sending c_shutdown(true) to ${shard} so its world is saved (timeout ${STOP_TIMEOUT_SECONDS}s)..."
            send_console "${shard}" 'c_shutdown(true)'
        fi
        # EOF on the console after the command, or the shard never exits (see open_console).
        close_console "${shard}"
    done
    (
        close_inherited_fds
        sleep "${STOP_TIMEOUT_SECONDS}"
        kill -USR2 $$ 2>/dev/null
    ) &
    STOP_TIMER_PID=$!
}

# shellcheck disable=SC2329  # invoked from the USR2 trap
force_stop_all() {
    local shard
    for shard in "${SHARDS[@]}"; do
        if shard_alive "${shard}"; then
            log "${shard} did not exit within ${STOP_TIMEOUT_SECONDS}s; sending SIGTERM." >&2
            kill -TERM "${SHARD_PID[${shard}]}" 2>/dev/null || true
            FORCE_KILLED=1
        fi
    done
}

cancel_stop_timer() {
    if [[ -n "${STOP_TIMER_PID}" ]]; then
        kill "${STOP_TIMER_PID}" 2>/dev/null || true
        wait "${STOP_TIMER_PID}" 2>/dev/null || true
        STOP_TIMER_PID=""
    fi
}

any_shard_alive() {
    local shard
    for shard in "${SHARDS[@]}"; do
        shard_alive "${shard}" && return 0
    done
    return 1
}

# Waits for the shards. Returns 0 when every shard exited after a requested stop, 1 when one died on its own
# (the others are then shut down first).
supervise() {
    local shard rc unexpected=0
    while any_shard_alive; do
        # A signal interrupts wait (status > 128); the trap has run by then and the loop re-checks.
        wait -n "${SHARD_PID[@]}" 2>/dev/null || true
        for shard in "${SHARDS[@]}"; do
            [[ -n "${SHARD_PID[${shard}]:-}" ]] || continue
            if ! kill -0 "${SHARD_PID[${shard}]}" 2>/dev/null; then
                wait "${SHARD_PID[${shard}]}" 2>/dev/null; rc=$?
                SHARD_RC["${shard}"]="${rc}"
                unset "SHARD_PID[${shard}]"
                close_console "${shard}"
                if (( STOP_REQUESTED )); then
                    log "${shard} exited (code ${rc})."
                else
                    log "${shard} exited unexpectedly (code ${rc}); shutting the cluster down." >&2
                    unexpected=1
                    request_stop_all
                fi
            fi
        done
    done
    cancel_stop_timer
    return "${unexpected}"
}

# shellcheck disable=SC2329  # trap handlers
on_term() { log "Stop requested (signal)."; request_stop_all; }
# shellcheck disable=SC2329
on_usr1() { request_stop_all; }
# shellcheck disable=SC2329
on_usr2() { force_stop_all; }

main() {
    trap on_term INT TERM
    trap on_usr1 USR1
    trap on_usr2 USR2

    validate_env
    adjust_permissions
    check_data_dir
    generate_cluster
    resolve_token
    open_output

    local exit_code=0
    while true; do
        STOP_REQUESTED=0
        FORCE_KILLED=0
        SHARD_RC=()
        maybe_update_server
        launch_shards
        start_auto_update_monitor
        if supervise; then
            exit_code=0
        else
            exit_code=1
        fi
        stop_auto_update_monitor
        (( FORCE_KILLED )) && exit_code=1

        if [[ -f "${AUTO_UPDATE_FLAG_FILE}" && "${exit_code}" -eq 0 ]]; then
            log "Auto-update: restarting the shards on the new build."
            continue
        fi
        break
    done
    close_output
    log "Cluster stopped (exit ${exit_code}; shards:$(for s in "${!SHARD_RC[@]}"; do printf ' %s=%s' "${s}" "${SHARD_RC[$s]}"; done))."
    exit "${exit_code}"
}

main "$@"
