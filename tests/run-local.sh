#!/bin/bash
# Local/CI test suite for the dst-server image. Everything runs in OFFLINE mode (offline_cluster = true),
# so no Klei token is needed and nothing is ever listed publicly. Usage:
#
#   IMAGE=dst-server:local tests/run-local.sh          # run every case
#   IMAGE=dst-server:local tests/run-local.sh clean    # remove containers and the test data directories
#
# Cases
#   fresh       empty /data, PUID/PGID other than 1000: generated config, both shards start and link, ports
#               bound, ownership, healthcheck, console + token redaction, docker stop saves and exits 0
#   reload      second start on the same /data with UPDATE_ON_START=true: DepotDownloader validates, the
#               existing world is loaded (not regenerated), stop saves again
#   caves-off   CAVES=false: Master only, no Caves directory generated
#   no-token    online cluster without a token refuses to start (exit 1) before launching anything
#   shard-dies  SIGKILL on the Caves process: Master is shut down cleanly and the container exits non-zero
#   auto-update  stop with the AUTO_UPDATE_INTERVAL_MINUTES monitor running still saves and exits 0
#   healthcheck the pgrep pattern does not match when no shard runs
#   no-caves-dir existing cluster without Caves/ while CAVES=true is refused, and the cluster is untouched
set -euo pipefail

IMAGE="${IMAGE:-dst-server:local}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_ROOT="${HERE}/data"
PREFIX="dst-test"
# Ids nobody on the host is likely to have, to prove the remap; the data directories are handed to them
# through a throwaway container because the host user cannot chown to them directly.
TEST_UID=1234
TEST_GID=1235
FAKE_TOKEN='pds-g^KU_FAKE_TOKEN_FOR_TESTS_ONLY^0123456789abcdef='
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$*" >&2; }
check() { # check <description> <command...>
    local desc="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "${desc}"; else fail "${desc}"; fi
}

cleanup() {
    docker ps -aq --filter "name=^${PREFIX}-" | xargs -r docker rm -f >/dev/null 2>&1 || true
    if [[ -d "${DATA_ROOT}" ]]; then
        docker run --rm -v "${DATA_ROOT}:/d" busybox sh -c 'rm -rf /d/*' >/dev/null 2>&1 || true
        rmdir "${DATA_ROOT}" 2>/dev/null || true
    fi
}

if [[ "${1:-}" == "clean" ]]; then
    cleanup
    exit 0
fi

fresh_data() { # fresh_data <name> -> prints the host path of an empty directory owned by TEST_UID:TEST_GID
    local d="${DATA_ROOT}/$1"
    mkdir -p "${d}"
    docker run --rm -v "${d}:/d" busybox sh -c "rm -rf /d/* && chown ${TEST_UID}:${TEST_GID} /d" >/dev/null
    printf '%s' "${d}"
}

# in_data <dir> <command...>: run a command against a data directory as root inside busybox (the files
# belong to TEST_UID, so the host user cannot read them all).
in_data() { local d="$1"; shift; docker run --rm -v "${d}:/d" busybox sh -c "cd /d && $*"; }

run_container() { # run_container <name> <data dir> [env...]
    local name="$1" data="$2"; shift 2
    local args=()
    local e
    for e in "$@"; do args+=(-e "${e}"); done
    docker run -d --name "${name}" --init -e "PUID=${TEST_UID}" -e "PGID=${TEST_GID}" -e OFFLINE_CLUSTER=true \
        -e UPDATE_ON_START=false "${args[@]}" -v "${data}:/data" "${IMAGE}" >/dev/null
}

wait_for_log() { # wait_for_log <container> <regex> <seconds> [min count]
    local name="$1" pattern="$2" limit="$3" want="${4:-1}" i
    for (( i = 0; i < limit; i++ )); do
        if [[ "$(docker logs "${name}" 2>&1 | grep -cE "${pattern}")" -ge "${want}" ]]; then return 0; fi
        if [[ "$(docker inspect "${name}" --format '{{.State.Running}}')" != "true" ]]; then return 1; fi
        sleep 1
    done
    return 1
}

wait_for_exit() { # wait_for_exit <container> <seconds>
    local name="$1" limit="$2" i
    for (( i = 0; i < limit; i++ )); do
        [[ "$(docker inspect "${name}" --format '{{.State.Running}}')" == "true" ]] || return 0
        sleep 1
    done
    return 1
}

exit_code() { docker inspect "$1" --format '{{.State.ExitCode}}'; }
health()    { docker inspect "$1" --format '{{.State.Health.Status}}'; }
# Checks written as `bash -c "..."` need the helpers in the child shell.
export -f in_data exit_code health
# UDP ports bound inside the container, decimal, from /proc/net/udp (the image has no ss).
udp_ports() { docker exec "$1" bash -c 'awk '"'"'NR>1 { split($2, a, ":"); print a[2] }'"'"' /proc/net/udp | while read -r h; do printf "%d\n" "0x${h}"; done | sort -un'; }
latest_save() { in_data "$1" "find $2/save/session -type f ! -name '*.meta' 2>/dev/null | sort | tail -n 1"; }

cleanup
# Containers and data are removed on a clean pass only; after a failure (or an abort) they stay for inspection
# and `tests/run-local.sh clean` removes them.
trap '[[ "${FAIL}" -eq 0 && "$?" -eq 0 ]] && cleanup' EXIT

echo "== fresh: first start on an empty /data (PUID=${TEST_UID} PGID=${TEST_GID}, offline, Master + Caves)"
D1="$(fresh_data fresh)"
run_container "${PREFIX}-fresh" "${D1}" CLUSTER_NAME='Test Cluster' CLUSTER_DESCRIPTION='suite' MAX_PLAYERS=6 \
    GAME_MODE=endless PVP=false PAUSE_WHEN_EMPTY=true CAVES=true "CLUSTER_TOKEN=${FAKE_TOKEN}"
check "fresh: Master and Caves both serve within 180s (session identifier announced)" wait_for_log "${PREFIX}-fresh" 'Telling Client our new session identifier' 180 2
check "fresh: both shards pause when empty (PAUSE_WHEN_EMPTY=true)" wait_for_log "${PREFIX}-fresh" 'Sim paused' 60 2
check "fresh: Caves connected to Master" wait_for_log "${PREFIX}-fresh" '\[Master\] .*\[Shard\] Secondary shard Caves\([0-9]+\) connected' 30
check "fresh: Caves logs its Master connection" wait_for_log "${PREFIX}-fresh" '\[Caves\] .*\[Shard\] Connecting to master' 5
check "fresh: entrypoint generated the cluster" wait_for_log "${PREFIX}-fresh" '\[entrypoint\] Generated .*cluster.ini, Master/server.ini, Caves/server.ini, Caves/worldgenoverride.lua' 5

CI="$(in_data "${D1}" cat DoNotStarveTogether/Cluster_1/cluster.ini)"; export CI
check "fresh: cluster.ini game_mode = endless"        grep -qx 'game_mode = endless' <<<"${CI}"
check "fresh: cluster.ini max_players = 6"            grep -qx 'max_players = 6' <<<"${CI}"
check "fresh: cluster.ini pvp = false"                grep -qx 'pvp = false' <<<"${CI}"
check "fresh: cluster.ini pause_when_empty = true"    grep -qx 'pause_when_empty = true' <<<"${CI}"
check "fresh: cluster.ini cluster_name"               grep -qx 'cluster_name = Test Cluster' <<<"${CI}"
check "fresh: cluster.ini offline_cluster = true"     grep -qx 'offline_cluster = true' <<<"${CI}"
check "fresh: cluster.ini shard_enabled = true"       grep -qx 'shard_enabled = true' <<<"${CI}"
check "fresh: cluster.ini has a cluster_key"          grep -qE '^cluster_key = [0-9a-f]{48}$' <<<"${CI}"
check "fresh: cluster.ini never carries cluster_password" bash -c "! grep -q cluster_password <<<\"\${CI}\""
check "fresh: Master/server.ini is_master + 10999 + steam 12346/12347" bash -c "in_data '${D1}' cat DoNotStarveTogether/Cluster_1/Master/server.ini | grep -qx 'is_master = true' && in_data '${D1}' cat DoNotStarveTogether/Cluster_1/Master/server.ini | grep -qx 'server_port = 10999' && in_data '${D1}' cat DoNotStarveTogether/Cluster_1/Master/server.ini | grep -qx 'master_server_port = 12346'"
check "fresh: Caves/server.ini is_master = false + 11000 + name" bash -c "in_data '${D1}' cat DoNotStarveTogether/Cluster_1/Caves/server.ini | grep -qx 'is_master = false' && in_data '${D1}' cat DoNotStarveTogether/Cluster_1/Caves/server.ini | grep -qx 'server_port = 11000' && in_data '${D1}' cat DoNotStarveTogether/Cluster_1/Caves/server.ini | grep -qx 'name = Caves'"
check "fresh: Caves/worldgenoverride.lua uses the DST_CAVE preset" bash -c "in_data '${D1}' cat DoNotStarveTogether/Cluster_1/Caves/worldgenoverride.lua | grep -q 'preset = \"DST_CAVE\"'"
check "fresh: the game applied the settings (MaxPlayers: 6, GameMode: endless, PauseWhenEmpty: true)" bash -c "docker logs ${PREFIX}-fresh 2>&1 | grep -q 'MaxPlayers: 6' && docker logs ${PREFIX}-fresh 2>&1 | grep -q 'GameMode: endless' && docker logs ${PREFIX}-fresh 2>&1 | grep -q 'PauseWhenEmpty: true'"

PORTS="$(udp_ports "${PREFIX}-fresh")"
check "fresh: 10999/udp bound (Master)"  grep -qx 10999 <<<"${PORTS}"
check "fresh: 11000/udp bound (Caves)"   grep -qx 11000 <<<"${PORTS}"
check "fresh: 10888/udp bound (shard link)" grep -qx 10888 <<<"${PORTS}"
check "fresh: two server processes, one per shard" bash -c "[ \"\$(docker exec ${PREFIX}-fresh pgrep -fc 'dontstarve_dedicated_server_nullrenderer_x64 -persistent')\" -eq 2 ]"
check "fresh: shards run as ${TEST_UID}" bash -c "docker exec ${PREFIX}-fresh ps -o uid= -p \"\$(docker exec ${PREFIX}-fresh pgrep -f 'nullrenderer_x64 .*-shard Master')\" | grep -qw ${TEST_UID}"
check "fresh: every file under /data is owned ${TEST_UID}:${TEST_GID}" bash -c "[ -z \"\$(in_data '${D1}' find . ! -user ${TEST_UID} -o ! -group ${TEST_GID} | head -n 1)\" ]"
check "fresh: cluster_token.txt written 0600 with the token" bash -c "[ \"\$(in_data '${D1}' stat -c %a DoNotStarveTogether/Cluster_1/cluster_token.txt)\" = 600 ] && [ \"\$(in_data '${D1}' cat DoNotStarveTogether/Cluster_1/cluster_token.txt)\" = '${FAKE_TOKEN}' ]"
check "fresh: the token never appears in the container log" bash -c "! docker logs ${PREFIX}-fresh 2>&1 | grep -qF '${FAKE_TOKEN}'"
check "fresh: healthcheck reports healthy" bash -c "for i in \$(seq 1 40); do [ \"\$(health ${PREFIX}-fresh)\" = healthy ] && exit 0; sleep 2; done; exit 1"

# Console: a Lua print typed into Master's FIFO from outside; the echo of the command carries the token and
# must come out redacted.
docker exec "${PREFIX}-fresh" sh -c "printf '%s\n' 'print(\"console-probe ${FAKE_TOKEN}\")' > /tmp/dst-console-Master"
check "fresh: console command reaches Master (RemoteCommandInput)" wait_for_log "${PREFIX}-fresh" 'RemoteCommandInput: "print\("console-probe' 15
check "fresh: token in console output is redacted to ****" bash -c "docker logs ${PREFIX}-fresh 2>&1 | grep -q 'console-probe \*\*\*\*' && ! docker logs ${PREFIX}-fresh 2>&1 | grep -qF '${FAKE_TOKEN}'"

echo "== fresh: docker stop must save both worlds and exit 0"
M_BEFORE="$(latest_save "${D1}" DoNotStarveTogether/Cluster_1/Master)"
C_BEFORE="$(latest_save "${D1}" DoNotStarveTogether/Cluster_1/Caves)"
T0=$(date +%s)
docker stop -t 300 "${PREFIX}-fresh" >/dev/null
T_STOP=$(( $(date +%s) - T0 ))
M_AFTER="$(latest_save "${D1}" DoNotStarveTogether/Cluster_1/Master)"
C_AFTER="$(latest_save "${D1}" DoNotStarveTogether/Cluster_1/Caves)"
check "fresh: docker stop returned within 60s (took ${T_STOP}s)" test "${T_STOP}" -le 60
check "fresh: exit code 0 (was $(exit_code "${PREFIX}-fresh"))" test "$(exit_code "${PREFIX}-fresh")" -eq 0
check "fresh: Master wrote a new save on stop (${M_BEFORE##*/} -> ${M_AFTER##*/})" test -n "${M_AFTER}" -a "${M_AFTER}" != "${M_BEFORE}"
check "fresh: Caves wrote a new save on stop (${C_BEFORE##*/} -> ${C_AFTER##*/})" test -n "${C_AFTER}" -a "${C_AFTER}" != "${C_BEFORE}"
check "fresh: log shows c_shutdown, 'Saving Dedicated server data' and 'Shutting down' for both shards" bash -c "L=\"\$(docker logs ${PREFIX}-fresh 2>&1)\"; grep -q 'Sending c_shutdown(true) to Caves' <<<\"\$L\" && grep -q 'Sending c_shutdown(true) to Master' <<<\"\$L\" && [ \"\$(grep -c 'Saving Dedicated server data' <<<\"\$L\")\" -ge 2 ] && [ \"\$(grep -c 'Shutting down' <<<\"\$L\")\" -ge 2 ] && grep -q 'Cluster stopped (exit 0' <<<\"\$L\""

echo "== reload: second start on the same /data with UPDATE_ON_START=true"
CI_BEFORE="$(in_data "${D1}" sha256sum DoNotStarveTogether/Cluster_1/cluster.ini DoNotStarveTogether/Cluster_1/Master/server.ini DoNotStarveTogether/Cluster_1/Caves/server.ini)"
run_container "${PREFIX}-reload" "${D1}" UPDATE_ON_START=true CLUSTER_NAME='Ignored On Reload' MAX_PLAYERS=64
check "reload: DepotDownloader validated the install (Total downloaded)" wait_for_log "${PREFIX}-reload" '^Total downloaded: ' 600
check "reload: entrypoint reports the validated build" wait_for_log "${PREFIX}-reload" '\[entrypoint\] DepotDownloader: done in [0-9]+s; build [0-9]+' 30
check "reload: existing cluster used, nothing generated" wait_for_log "${PREFIX}-reload" '\[entrypoint\] Using the existing cluster' 5
check "reload: config files unchanged" test "$(in_data "${D1}" sha256sum DoNotStarveTogether/Cluster_1/cluster.ini DoNotStarveTogether/Cluster_1/Master/server.ini DoNotStarveTogether/Cluster_1/Caves/server.ini)" = "${CI_BEFORE}"
check "reload: both shards load the existing worlds (Loading world: session/)" wait_for_log "${PREFIX}-reload" 'Loading world: session/' 180 2
check "reload: both shards up again" wait_for_log "${PREFIX}-reload" 'Telling Client our new session identifier' 180 2
check "reload: no new world generated" bash -c "! docker logs ${PREFIX}-reload 2>&1 | grep -q 'running worldgen_main.lua'"
docker stop -t 300 "${PREFIX}-reload" >/dev/null
check "reload: stop exits 0" test "$(exit_code "${PREFIX}-reload")" -eq 0

echo "== caves-off: CAVES=false"
D2="$(fresh_data cavesoff)"
run_container "${PREFIX}-cavesoff" "${D2}" CAVES=false
check "caves-off: Master serves" wait_for_log "${PREFIX}-cavesoff" 'Telling Client our new session identifier' 180
check "caves-off: one server process" bash -c "[ \"\$(docker exec ${PREFIX}-cavesoff pgrep -fc 'dontstarve_dedicated_server_nullrenderer_x64 -persistent')\" -eq 1 ]"
check "caves-off: no Caves directory, no [SHARD] section" bash -c "! in_data '${D2}' test -e DoNotStarveTogether/Cluster_1/Caves && ! in_data '${D2}' grep -q shard_enabled DoNotStarveTogether/Cluster_1/cluster.ini"
docker stop -t 300 "${PREFIX}-cavesoff" >/dev/null
check "caves-off: stop exits 0" test "$(exit_code "${PREFIX}-cavesoff")" -eq 0

echo "== no-token: an online cluster without a token is refused"
D3="$(fresh_data notoken)"
docker run -d --name "${PREFIX}-notoken" --init -e "PUID=${TEST_UID}" -e "PGID=${TEST_GID}" -e OFFLINE_CLUSTER=false -e UPDATE_ON_START=false -v "${D3}:/data" "${IMAGE}" >/dev/null
check "no-token: container exits" wait_for_exit "${PREFIX}-notoken" 30
check "no-token: exit code 1" test "$(exit_code "${PREFIX}-notoken")" -eq 1
check "no-token: the message names the token and the fix" bash -c "docker logs ${PREFIX}-notoken 2>&1 | grep -q 'No cluster token'"
check "no-token: no shard was launched" bash -c "! docker logs ${PREFIX}-notoken 2>&1 | grep -q 'Starting shard'"

echo "== shard-dies: SIGKILL on Caves"
run_container "${PREFIX}-dies" "${D1}"
check "shard-dies: both shards up" wait_for_log "${PREFIX}-dies" 'Telling Client our new session identifier' 180 2
M_BEFORE="$(latest_save "${D1}" DoNotStarveTogether/Cluster_1/Master)"
# [n]ullrenderer: the pattern must not match this sh -c's own command line, or pgrep kills the wrapper (exit 137).
docker exec "${PREFIX}-dies" sh -c "kill -KILL \$(pgrep -f '[n]ullrenderer_x64 .*-shard Caves')"
check "shard-dies: container exits within 60s" wait_for_exit "${PREFIX}-dies" 60
check "shard-dies: exit code non-zero (was $(exit_code "${PREFIX}-dies"))" test "$(exit_code "${PREFIX}-dies")" -ne 0
check "shard-dies: Caves reported as exited unexpectedly, Master shut down via console" bash -c "L=\"\$(docker logs ${PREFIX}-dies 2>&1)\"; grep -q 'Caves exited unexpectedly' <<<\"\$L\" && grep -q 'Sending c_shutdown(true) to Master' <<<\"\$L\""
check "shard-dies: Master saved on the way down" test "$(latest_save "${D1}" DoNotStarveTogether/Cluster_1/Master)" != "${M_BEFORE}"

echo "== auto-update: stop while the AUTO_UPDATE_INTERVAL_MINUTES monitor is running"
# The monitor is a background subshell; it must not hold the shards' console FIFOs open or the stop hangs
# (the shard waits for EOF on stdin after c_shutdown). Found 2026-09-22; this pins the fix.
run_container "${PREFIX}-autoupd" "${D2}" CAVES=false AUTO_UPDATE_INTERVAL_MINUTES=1
check "auto-update: monitor enabled" wait_for_log "${PREFIX}-autoupd" 'Auto-update: enabled; checking for new builds every 1 minute' 30
check "auto-update: Master serves" wait_for_log "${PREFIX}-autoupd" 'Telling Client our new session identifier' 180
sleep 75   # let one manifest-only check run (it logs nothing when the build is current)
check "auto-update: no spurious update detected" bash -c "! docker logs ${PREFIX}-autoupd 2>&1 | grep -q 'Auto-update: new build detected'"
T0=$(date +%s)
docker stop -t 300 "${PREFIX}-autoupd" >/dev/null
T_STOP=$(( $(date +%s) - T0 ))
check "auto-update: docker stop returned within 60s with the monitor running (took ${T_STOP}s)" test "${T_STOP}" -le 60
check "auto-update: exit code 0 (was $(exit_code "${PREFIX}-autoupd"))" test "$(exit_code "${PREFIX}-autoupd")" -eq 0

echo "== healthcheck: the pattern does not self-match"
check "healthcheck: pgrep pattern finds nothing in a container with no shard" bash -c "! docker run --rm --entrypoint pgrep '${IMAGE}' -f 'dontstarve_dedicated_server_nullrenderer_x64 .*-shard Master'"

echo "== no-caves-dir: existing cluster without Caves/ while CAVES=true"
D4="$(fresh_data nocavesdir)"
docker run --rm -v "${D2}:/src" -v "${D4}:/d" busybox sh -c "cp -a /src/. /d/ && chown -R ${TEST_UID}:${TEST_GID} /d" >/dev/null
SUM_BEFORE="$(in_data "${D4}" "find DoNotStarveTogether/Cluster_1 -maxdepth 2 -type f -name '*.ini' -exec sha256sum {} +" | sort)"
run_container "${PREFIX}-nocaves" "${D4}" CAVES=true
check "no-caves-dir: container exits" wait_for_exit "${PREFIX}-nocaves" 30
check "no-caves-dir: exit code 1" test "$(exit_code "${PREFIX}-nocaves")" -eq 1
check "no-caves-dir: message names the missing server.ini" bash -c "docker logs ${PREFIX}-nocaves 2>&1 | grep -q 'Caves/server.ini is missing'"
check "no-caves-dir: existing cluster untouched" test "$(in_data "${D4}" "find DoNotStarveTogether/Cluster_1 -maxdepth 2 -type f -name '*.ini' -exec sha256sum {} +" | sort)" = "${SUM_BEFORE}"

echo
echo "${PASS} PASS / ${FAIL} FAIL"
[[ "${FAIL}" -eq 0 ]]
