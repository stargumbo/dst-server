# Don't Starve Together dedicated server for linux/amd64: Master (Forest) and Caves shards in one container,
# game files fetched from Steam by DepotDownloader (anonymous dedicated-server subscription).
#
# Stages
#   depotdownloader  The official DepotDownloader release, downloaded and sha256-verified, copied into the
#                    runtime image: UPDATE_ON_START and AUTO_UPDATE_INTERVAL_MINUTES fetch through it at run time.
#   game             The current Steam build of the server (app 343050), fetched fresh at build time. Nothing is
#                    pre-installed from an older release: an image that ships a stale Steam install cannot be
#                    delta-updated anonymously later (Steam stops issuing manifest request codes for old
#                    manifests), which is why this image exists at all.
#   deps             Runs ldd on the server binary against the runtime base to list the shared libraries the
#                    game needs, so the runtime stage installs exactly those packages and the build fails loudly
#                    if the base ever stops providing one.
#   (runtime)        debian:trixie-slim plus the packages `deps` proved necessary, gosu, the two stages above,
#                    the entrypoint and the redactor.
#
# DepotDownloader (https://github.com/SteamRE/DepotDownloader) is GPL-2.0 and is used exactly as released:
# fetched by the version and sha256 pinned here, never built from source, patched or vendored. See NOTICE.

ARG DD_VERSION=3.4.0
ARG DD_RELEASE_URL=https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DD_VERSION}
# sha256 of DepotDownloader-linux-x64.zip from that release (the arm64 value is unused: no arm64 DST server exists).
ARG DD_SHA256_AMD64=a999dec66b4850fc961bd50366696d23c2d0fad7b18790e6a5647b2f19097a53
ARG DD_SHA256_ARM64=d9fb612ccebc1db8eeea3b4045d2221ec70431381393ce908fb72f01d4f9c812

# ---------------------------------------------------------------------------------------------------------
FROM debian:trixie-slim AS depotdownloader
ARG DD_VERSION DD_RELEASE_URL DD_SHA256_AMD64 DD_SHA256_ARM64
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*
COPY --chmod=755 scripts/fetch-depotdownloader.sh /usr/local/bin/fetch-depotdownloader
RUN fetch-depotdownloader amd64 /opt/depotdownloader

# ---------------------------------------------------------------------------------------------------------
FROM debian:trixie-slim AS game
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# DepotDownloader is a self-contained .NET binary; libicu is the one thing it needs from the OS.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libicu76 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=depotdownloader /opt/depotdownloader /dd

# STEAM_REFRESH is part of the cache key of the RUN below (an ARG declared before a RUN is), so the weekly
# rebuild, which passes a fresh value, downloads the current Steam build even when nothing else changed.
ARG STEAM_REFRESH=
# The filelist is the one entrypoint.sh uses for UPDATE_ON_START: everything except bin/ (the 32-bit server,
# never run). DepotDownloader still creates a directory for every path in the manifest, hence the
# empty-directory cleanup; a file under bin/ means the filelist stopped matching, and the build fails.
# Steam's manifest carries no Unix mode bits through DepotDownloader, so the server binary is chmod'ed here
# (and by the entrypoint after every run-time update). The tree is made group-writable so that a run user
# remapped by PUID/PGID can still update it through its supplementary gid 1000 without a 4 GB chown (see
# entrypoint.sh, adjust_permissions).
# .dst-manifests records the depot manifests this download installed, in the format entrypoint.sh's
# manifests_from_log produces, so the auto-update check has a baseline from the very first start.
RUN printf 'regex:^(?!bin/).*$\n' > /tmp/filelist \
 && /dd/DepotDownloader -app 343050 -os linux -osarch 64 -dir /app -filelist /tmp/filelist 2>&1 | tee /tmp/depotdownloader.log \
 && grep -q '^Total downloaded: ' /tmp/depotdownloader.log
RUN test -f /app/bin64/dontstarve_dedicated_server_nullrenderer_x64 \
 && chmod 755 /app/bin64/dontstarve_dedicated_server_nullrenderer_x64 \
 && test -s /app/version.txt \
 && sed -n -e 's/^Got manifest request code for depot \([0-9]*\) from app [0-9]*, manifest \([0-9]*\),.*/\1 \2/p' \
           -e 's/^Already have manifest \([0-9]*\) for depot \([0-9]*\)\..*/\2 \1/p' /tmp/depotdownloader.log \
    | sort -u > /app/.dst-manifests \
 && test -s /app/.dst-manifests \
 && if [ -n "$(find /app/bin -type f 2>/dev/null | head -n 1)" ]; then echo "the filelist did not exclude bin/" >&2; exit 1; fi \
 && rm -rf /app/bin /app/.DepotDownloader \
 && find /app -depth -type d -empty -delete \
 && chmod -R g+w /app \
 && echo "DST build $(cat /app/version.txt)" && cat /app/.dst-manifests && du -sh /app

# ---------------------------------------------------------------------------------------------------------
# Which shared libraries the server binary needs that the bare base does not provide. The list is asserted
# against the packages installed in the runtime stage: a new library dependency fails the build here instead
# of failing the first start.
FROM debian:trixie-slim AS deps
COPY --from=game /app/bin64/dontstarve_dedicated_server_nullrenderer_x64 /probe/server
COPY --from=game /app/bin64/lib64 /probe/lib64
RUN LD_LIBRARY_PATH=/probe/lib64 ldd /probe/server | awk '/not found/ { print $1 }' | sort > /probe/missing.txt \
 && echo "libraries the base image lacks:" && cat /probe/missing.txt

# ---------------------------------------------------------------------------------------------------------
FROM debian:trixie-slim

ARG BUILD_VERSION=dev
ARG BUILD_REVISION=unknown
ARG uid=1000
ARG gid=1000

# Recorded from the deps stage on 2026-09-22 against debian:trixie-slim (see README "Runtime packages"):
#   libcurl-gnutls.so.4 -> libcurl3t64-gnutls (the game's only dependency outside its own lib64/ and glibc)
#   libstdc++.so.6 / libgcc_s.so.1 -> libstdc++6 (pulled in as a dependency of libcurl3t64-gnutls, listed for clarity)
# gosu drops privileges in the entrypoint; procps provides pgrep for the healthcheck; libicu for DepotDownloader.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates gosu procps libicu76 libcurl3t64-gnutls libstdc++6 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd -g ${gid} dst && useradd -u ${uid} -g dst -s /bin/bash -m dst \
 && mkdir -p /data /home/dst/.local/share && chown -R dst:dst /home/dst

COPY --from=depotdownloader /opt/depotdownloader /opt/depotdownloader
COPY --from=game --chown=dst:dst /app /app
COPY --from=deps /probe/missing.txt /usr/share/doc/dst-server/ldd-missing.txt
COPY --chown=dst:dst --chmod=755 entrypoint.sh redact.sh /app/
COPY NOTICE /usr/share/doc/dst-server/NOTICE
# COPY recreates the top-level target directory with default modes; the tree below it kept the game stage's
# g+w, and the directory itself needs it too (DepotDownloader creates /app/.DepotDownloader at run time).
RUN chmod 775 /app
WORKDIR /app

# Every library ldd reported missing against the bare base must resolve now, DepotDownloader must run, and the
# game tree must be what the game stage promised.
RUN cd /app/bin64 && LD_LIBRARY_PATH=/app/bin64/lib64 ldd ./dontstarve_dedicated_server_nullrenderer_x64 \
      | tee /tmp/ldd.txt | grep -q 'libcurl-gnutls' \
 && if grep -q 'not found' /tmp/ldd.txt; then echo "unresolved libraries:" >&2; grep 'not found' /tmp/ldd.txt >&2; exit 1; fi \
 && /opt/depotdownloader/DepotDownloader -V \
 && test -s /app/version.txt && test -s /app/.dst-manifests && test ! -e /app/bin \
 && rm -f /tmp/ldd.txt

LABEL org.opencontainers.image.title="Don't Starve Together Dedicated Server" \
      org.opencontainers.image.description="Don't Starve Together dedicated server (Master + Caves shards in one container) on Debian, game files fetched from Steam by DepotDownloader (anonymous)." \
      org.opencontainers.image.source="https://github.com/stargumbo/dst-server" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${BUILD_VERSION}" \
      org.opencontainers.image.revision="${BUILD_REVISION}"

# Runtime identity and server defaults (all overridable at run time; see README). CLUSTER_TOKEN and
# CLUSTER_TOKEN_FILE are deliberately not defaulted: pass one at run time (or put the token in
# Cluster_1/cluster_token.txt yourself). The image never reads, writes or logs cluster_password.
ENV CONTAINER_USER=dst CONTAINER_GROUP=dst CONTAINER_UID=${uid} CONTAINER_GID=${gid} \
    CAVES=true UPDATE_ON_START=true AUTO_UPDATE_INTERVAL_MINUTES=0 STOP_TIMEOUT_SECONDS=240 \
    CLUSTER_NAME= CLUSTER_DESCRIPTION= CLUSTER_INTENTION=cooperative MAX_PLAYERS=16 \
    GAME_MODE=survival PVP=false PAUSE_WHEN_EMPTY=false OFFLINE_CLUSTER=false

# 10999 Master, 11000 Caves (players); 12346/12347 Master's Steam master-server and authentication ports.
EXPOSE 10999/udp 11000/udp 12346/udp 12347/udp
# Exec form on purpose: a shell-form check would run inside `sh -c "pgrep -f ..."`, whose own argv contains
# the pattern, so pgrep would match the wrapper and the container would always be "healthy". Healthy only
# while the Master shard process is alive, i.e. not during the DepotDownloader run before it.
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD ["pgrep", "-f", "dontstarve_dedicated_server_nullrenderer_x64 .*-shard Master"]
VOLUME ["/data"]

ENTRYPOINT ["/app/entrypoint.sh"]
CMD []
