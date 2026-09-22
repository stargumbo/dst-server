# dst-server

A maintained Docker image for the **Don't Starve Together dedicated server**: the Master (Forest) and Caves
shards in one container, on Debian, with the game fetched **fresh from Steam at build time** and re-validated
at every start by [DepotDownloader](https://github.com/SteamRE/DepotDownloader).

```
ghcr.io/stargumbo/dst-server:1        docker.io/stargumbo/dst-server:1
```

linux/amd64 only (Klei ships no arm64 server). Pull-only; there is nothing to build on the host.

## Why another DST image

The widely used images pre-install a years-old Steam build and rely on `steamcmd app_update` at start to
bring it current. That stopped working: Steam no longer issues manifest request codes to the anonymous
account for those old manifests, so `app_update 343050` fails with `Access Denied` / `state is 0x6` and the
container crash-loops before it ever asks for a token (observed 2026-09-21). A fresh anonymous install of
the same app works fine. This image therefore never ships a stale build: every image build downloads the
current one, a weekly rebuild keeps the published tags current, and `UPDATE_ON_START` validates against
Steam on every start.

## Quick start

```yaml
services:
  dst:
    image: ghcr.io/stargumbo/dst-server:1
    container_name: dst
    restart: unless-stopped
    stop_grace_period: 300s          # both shards save on stop; the game says this can take up to ~5 min
    init: true
    environment:
      PUID: 1000                     # owner of everything under ./data
      PGID: 1000
      CLUSTER_NAME: "My Cluster"     # first start only, see "Configuration"
      MAX_PLAYERS: 6
      GAME_MODE: endless
      PAUSE_WHEN_EMPTY: "true"
    ports:
      - "10999-11000:10999-11000/udp"   # 10999 Master, 11000 Caves
      - "12346-12347:12346-12347/udp"   # Master's Steam ports
    volumes:
      - ./data:/data
```

1. `docker compose up -d` once. The first start generates `data/DoNotStarveTogether/Cluster_1/` from the
   environment, then stops with a clear message: an online cluster needs a Klei token.
2. Get a token in the game client: *Account → Games → Don't Starve Together Servers → Add New Server*.
   Paste it into `data/DoNotStarveTogether/Cluster_1/cluster_token.txt` (or see `CLUSTER_TOKEN_FILE` below).
3. Optionally add a join password: `cluster_password = ...` under `[NETWORK]` in
   `data/DoNotStarveTogether/Cluster_1/cluster.ini`. This image never reads, writes or logs that key.
4. `docker compose up -d` again. Both worlds generate (a minute or two), then `docker logs dst` shows
   `[Master] ... Telling Client our new session identifier` and `[Shard] Secondary shard Caves(...) connected`.

Forward **UDP 10999** (and, if cave entry fails from outside, **UDP 11000**) to the host. Do not remap the
ports: the server tells Steam which port it listens on.

## Configuration

Everything the image does is driven by environment variables; the game itself is configured by the files
under `/data/DoNotStarveTogether/Cluster_1/`, exactly as Klei documents them.

| Variable | Default | Meaning |
| --- | --- | --- |
| `PUID`, `PGID` | `1000`, `1000` | uid/gid the shards run as; everything created under `/data` is owned by them. The image never re-owns `/data`; it must be writable by `PUID` before the first start. |
| `CAVES` | `true` | Run the Caves shard next to Master. Also decides whether `Caves/` is generated on the first start. |
| `CLUSTER_TOKEN_FILE` | – | Path to a file holding the Klei token (a compose/Docker secret). Written to `Cluster_1/cluster_token.txt` (mode 0600) at start, redacted from the container log. Wins over `CLUSTER_TOKEN`. |
| `CLUSTER_TOKEN` | – | The token itself, as an environment variable. Same handling. With neither set, the token already in `cluster_token.txt` is used. |
| `UPDATE_ON_START` | `true` | Run DepotDownloader with `-validate` against `/app` before launching (about a minute for the 4 GB install; downloads only what changed). DST clients must match the server build, so leave it on. |
| `AUTO_UPDATE_INTERVAL_MINUTES` | `0` | Poll Steam every N minutes while running. On a new build: `c_shutdown(true)` to both shards, fetch, relaunch. `0` disables. |
| `STOP_TIMEOUT_SECONDS` | `240` | How long a stop waits for the shards to save and exit after `c_shutdown(true)` before falling back to SIGTERM. Keep it below `stop_grace_period`. |

**First start only** (used to generate `cluster.ini`; ignored once it exists):

| Variable | Default | Writes |
| --- | --- | --- |
| `CLUSTER_NAME` | `Don't Starve Together` | `[NETWORK] cluster_name` |
| `CLUSTER_DESCRIPTION` | empty | `[NETWORK] cluster_description` |
| `CLUSTER_INTENTION` | `cooperative` | `[NETWORK] cluster_intention` (`cooperative`, `competitive`, `social`, `madness`) |
| `OFFLINE_CLUSTER` | `false` | `[NETWORK] offline_cluster`. `true` = LAN only, no token required, never listed. |
| `MAX_PLAYERS` | `16` | `[GAMEPLAY] max_players` (1..64) |
| `GAME_MODE` | `survival` | `[GAMEPLAY] game_mode` (`survival`, `endless`, `wilderness`) |
| `PVP` | `false` | `[GAMEPLAY] pvp` |
| `PAUSE_WHEN_EMPTY` | `false` | `[GAMEPLAY] pause_when_empty` |

### What the first start generates

With `CAVES=true` the entrypoint writes (values from the example above):

```ini
# Cluster_1/cluster.ini
[GAMEPLAY]
game_mode = endless
max_players = 6
pvp = false
pause_when_empty = true

[NETWORK]
cluster_name = My Cluster
cluster_description = 
cluster_intention = cooperative
offline_cluster = false

[MISC]
console_enabled = true

[SHARD]
shard_enabled = true
bind_ip = 127.0.0.1
master_ip = 127.0.0.1
master_port = 10888
cluster_key = <48 random hex characters>
```

```ini
# Cluster_1/Master/server.ini          # Cluster_1/Caves/server.ini
[NETWORK]                              [NETWORK]
server_port = 10999                    server_port = 11000

[SHARD]                                [SHARD]
is_master = true                       is_master = false
                                       name = Caves
[STEAM]
master_server_port = 12346             [STEAM]
authentication_port = 12347            master_server_port = 12348
                                       authentication_port = 12349
```

```lua
-- Cluster_1/Caves/worldgenoverride.lua
return {
  override_enabled = true,
  preset = "DST_CAVE",
}
```

Keys, sections and defaults follow Klei's [Dedicated Server Settings Guide](https://forums.kleientertainment.com/forums/topic/64552-dedicated-server-settings-guide/).
`cluster_password` is deliberately not written ("omit it for no password"): add it yourself. The Caves
shard's Steam ports only have to differ from Master's on the same machine; they are not published.

**An existing cluster is never modified.** If `cluster.ini` is present the environment's first-start
variables are ignored, and a missing `Caves/server.ini` while `CAVES=true` is an error, not something the
image papers over. A cluster generated by another image or by hand works as long as it has the standard
layout (`cluster.ini`, `Master/server.ini`, optionally `Caves/server.ini`).

### Mods

Steam Workshop mods are installed by listing them in `/app/mods/dedicated_server_mods_setup.lua`
(`ServerModSetup("<workshop id>")` / `ServerModCollectionSetup("<collection id>")`) and enabled per shard
in `Cluster_1/<shard>/modoverrides.lua`. The first file lives in the game install inside the image, so bind
mount your own copy over it:

```yaml
    volumes:
      - ./data:/data
      - ./dedicated_server_mods_setup.lua:/app/mods/dedicated_server_mods_setup.lua:ro
```

The server downloads the listed mods into `/app/ugc_mods/` at start (inside the container; they are
re-fetched after a recreate). This image adds nothing on top of Klei's mechanism.

## Runtime behaviour

**Two shards, one supervisor.** `entrypoint.sh` (bash) launches Master and Caves as
`dontstarve_dedicated_server_nullrenderer_x64 -persistent_storage_root /data -conf_dir DoNotStarveTogether -cluster Cluster_1 -shard <name>`
from `/app/bin64`, each with its own console FIFO on stdin, output prefixed `[Master]` / `[Caves]` and
passed through a redactor that masks the token. If either shard dies on its own the other is shut down
cleanly and the container exits non-zero, so `restart: unless-stopped` brings the whole cluster back.

**Stop.** `docker stop` sends `c_shutdown(true)` to Caves, then Master. Each shard logs `Saving Dedicated
server data...`, writes a new save under `<shard>/save/session/<id>/`, logs `Shutting down` and exits; the
container exits 0 (a two-shard cluster with small worlds stops in about 2 s). The supervisor then closes the
shard's console: the server's stdin thread otherwise blocks forever after `Shutting down` and the process
never exits. A shard still alive after `STOP_TIMEOUT_SECONDS` gets SIGTERM, which also saves but is the
fallback, not the plan. Save state is judged by the session files' mtimes, not by log lines.

**Healthcheck.** `pgrep -f 'dontstarve_dedicated_server_nullrenderer_x64 .*-shard Master'` in exec form:
healthy only while the Master shard process is alive, so `starting` during the DepotDownloader run and
world generation, `healthy` once Master is up, `unhealthy` if it dies. Start
period 120 s. `Sim paused` in the log means pause-when-empty kicked in, not that anything is wrong.

**Console.** Anything written to `/tmp/dst-console-Master` or `/tmp/dst-console-Caves` inside the
container is executed as Lua by that shard, e.g. `docker exec dst sh -c 'echo "c_save()" > /tmp/dst-console-Master'`.

**Ownership.** The shards run as `PUID:PGID` (with the image's gid 1000 as a supplementary group, which is
how they may update the 4 GB game tree in `/app` without it ever being re-owned). Files under `/data` are
created `PUID:PGID` with mode 644/755; `cluster_token.txt` is 0600. `/data` itself is never chowned: make
it writable by `PUID` on the host first.

**Logs.** The container log carries both shards' stdout. Each shard also writes
`Cluster_1/<shard>/server_log.txt` (and `server_chat_log.txt`) under `/data`.

## Runtime packages

Recorded from `ldd` on `bin64/dontstarve_dedicated_server_nullrenderer_x64` against `debian:trixie-slim`
(the `deps` stage does this on every build and the runtime stage fails if anything is left unresolved):

| Library | Package | Note |
| --- | --- | --- |
| `libcurl-gnutls.so.4` | `libcurl3t64-gnutls` | the only dependency the bare base lacks |
| `libstdc++.so.6`, `libgcc_s.so.1` | `libstdc++6` | already in the base; listed explicitly |
| `libSDL2-2.0.so.0`, `libfmodevent64.so`, `libfmodex64*.so`, `libsteam_api.so` | – | shipped by Klei in `bin64/lib64/` (rpath `./lib64`, which is why the server runs from `bin64/`) |
| `libicu76` | `libicu76` | for DepotDownloader (.NET), not the game |

Plus `gosu` (privilege drop), `procps` (`pgrep` for the healthcheck) and `ca-certificates`.

## Tags

| Tag | Meaning |
| --- | --- |
| `1`, `1.0`, `1.0.0`, `latest` | image releases (semver); re-pushed by the weekly rebuild while newest |
| `<build>` (e.g. `747465`) | the DST build number baked in, from `/app/version.txt`; moves only when Steam ships a new build |
| `1.0.0-<build>` | immutable pin of one image release with one game build |

Every tag is published to `ghcr.io/stargumbo/dst-server` and `docker.io/stargumbo/dst-server` with an
identical digest (the publish workflow verifies this before creating the game-build tags). A weekly
rebuild (Mondays 05:17 UTC) refreshes the base image and the Steam build.

## Development

```
docker build -t dst-server:local .
IMAGE=dst-server:local tests/run-local.sh        # offline cluster, no token; ~10 min
IMAGE=dst-server:local tests/run-local.sh clean
```

The suite covers first-start generation, shard linking, port binding, ownership under a non-default
PUID/PGID, healthcheck, console + token redaction, `docker stop` saving both worlds, a second start loading
the existing worlds with `UPDATE_ON_START=true`, `CAVES=false`, refusal without a token, refusal when
`Caves/` is missing, and a shard being killed.

## Credits and licenses

MIT (see `LICENSE`). Third-party components and their licenses are listed in `NOTICE`: DepotDownloader
(GPL-2.0, used as an unmodified release binary), the game files (Klei Entertainment, downloaded from Steam
at build time, not redistributed by this repository), Debian.

Prior art: [Jamesits/docker-dst-server](https://github.com/Jamesits/docker-dst-server) established the
`/data` layout, the port convention and the "up to ~5 minutes to save" stop timing that this image keeps.
It is GPL-2.0 and no code from it is used here. Structure and tooling follow
[stargumbo/necesse-server](https://github.com/stargumbo/necesse-server).
