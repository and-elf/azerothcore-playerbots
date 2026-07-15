#!/usr/bin/env bash
#
# Build AND run AzerothCore in the Ubuntu dev container using rootless podman.
#
# `./acore.sh docker ...` (podman-compose) fails on rootless-podman-on-Fedora for
# several unrelated reasons; this script drives podman directly and works around
# all of them:
#
#   1. podman-compose `run` + `depends_on` puts the one-off container in a pod
#      whose dependency isn't a member -> "container has joined pod ..." error.
#   2. The stock dev Dockerfile installs `mysql-server`, whose postinstall starts
#      mysqld and fails under buildah's rootless build isolation. We swap it for
#      `mysql-client` (the CLI the DB updater shells out to at runtime); the
#      server daemon is not needed - a separate mysql:8.4 container is the DB.
#   3. SELinux (Enforcing) denies the bind mount -> `--security-opt label=disable`.
#   4. Without keep-id, host files map to root inside the container while the
#      process runs as `acore`, breaking `cmake --install` and file ownership ->
#      `--userns=keep-id`.
#
# For builds we also avoid the compose `ac-build-dev` named volume: when empty it
# copy-ups from the host var/build and can drag a stale CMake cache into the
# container. Building against the host var/build dir avoids that.
#
# Usage:
#   apps/docker/podman-dev-build.sh [build|all|clean|configure|compile]  # compile (default: build)
#   apps/docker/podman-dev-build.sh up                    # start db + authserver + worldserver (with ports)
#   apps/docker/podman-dev-build.sh down                  # stop authserver + worldserver (db kept)
#   apps/docker/podman-dev-build.sh down --all            # also stop the database
#   apps/docker/podman-dev-build.sh status                # show container + db status
#   apps/docker/podman-dev-build.sh logs [world|auth|db]  # follow logs (default: world)
#   apps/docker/podman-dev-build.sh console               # attach to the worldserver console (Ctrl-P Ctrl-Q to detach)
#   apps/docker/podman-dev-build.sh account <user> <pass> [gmlevel]  # create an account (default gmlevel 3)
#
# Env overrides:
#   IMAGE=<tag>              dev image (default acore/ac-wotlk-dev-server:master)
#   REBUILD=1                force rebuilding the dev image
#   DB_PASS=<pw>             mysql root password (default: password)
#   DB_VOLUME=<name>         database volume (default: azerothcore-playerbots_ac-database)
#   CLIENT_DATA_VOLUME=<n>   client data volume with maps/dbc/vmaps/mmaps
#                            (default: azerothcore-wotlk_ac-client-data)
#   AUTH_PORT/WORLD_PORT/SOAP_PORT   host ports (default 3724/8085/7878)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IMAGE="${IMAGE:-acore/ac-wotlk-dev-server:master}"
UID_N="$(id -u)"
GID_N=1000  # container 'acore' group; matches compose default DOCKER_GROUP_ID

NETWORK="azerothcore-playerbots_ac-network"
DB_VOLUME="${DB_VOLUME:-azerothcore-playerbots_ac-database}"
CLIENT_DATA_VOLUME="${CLIENT_DATA_VOLUME:-azerothcore-wotlk_ac-client-data}"
DB_PASS="${DB_PASS:-password}"
DB_IMAGE="docker.io/mysql:8.4"
AUTH_PORT="${AUTH_PORT:-3724}"
WORLD_PORT="${WORLD_PORT:-8085}"
SOAP_PORT="${SOAP_PORT:-7878}"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

ensure_image() {
  if [[ "${REBUILD:-0}" == "1" ]] || ! podman image exists "$IMAGE"; then
    echo ">> Building dev image '$IMAGE' (mysql-server daemon -> mysql-client CLI)"
    local tmp_df
    tmp_df="$(mktemp)"
    # drop the mysqld daemon (fails under buildah) but keep a mysql CLI for the DB updater
    sed 's/mysql-server \\/mysql-client \\/' \
      "$REPO_ROOT/apps/docker/Dockerfile.dev-server" > "$tmp_df"
    podman build \
      -f "$tmp_df" --target dev \
      --build-arg USER_ID="$UID_N" --build-arg GROUP_ID="$GID_N" --build-arg DOCKER_USER=acore \
      -t "$IMAGE" "$REPO_ROOT"
    rm -f "$tmp_df"
  fi
}

# common DB-connection env for the server containers
server_env() {
  printf '%s\0' \
    "-e" "AC_LOGIN_DATABASE_INFO=ac-database;3306;root;${DB_PASS};acore_auth" \
    "-e" "AC_WORLD_DATABASE_INFO=ac-database;3306;root;${DB_PASS};acore_world" \
    "-e" "AC_CHARACTER_DATABASE_INFO=ac-database;3306;root;${DB_PASS};acore_characters" \
    "-e" "AC_PLAYERBOTS_DATABASE_INFO=ac-database;3306;root;${DB_PASS};acore_playerbots" \
    "-e" "AC_DATA_DIR=/azerothcore/env/dist/data" \
    "-e" "AC_LOGS_DIR=/azerothcore/env/dist/logs" \
    "-e" "AC_TEMP_DIR=/azerothcore/env/dist/temp" \
    "-e" "LD_LIBRARY_PATH=/azerothcore/var/build/obj/src/common:/azerothcore/var/build/obj/src/server/shared:/azerothcore/var/build/obj/src/server/database"
}
# The installed binaries link libcommon/libshared/libdatabase as shared libs but carry no RPATH, and
# these are not copied into env/dist/bin -- they live in the (bind-mounted) build tree. Point the
# runtime linker at them so the from-source worldserver/authserver start. Applies to static and
# dynamic module builds alike; dynamic module .so's resolve their core symbols from the loaded process.

ensure_network() {
  podman network exists "$NETWORK" 2>/dev/null || podman network create "$NETWORK" >/dev/null
}

ensure_database() {
  if [[ "$(podman inspect ac-database --format '{{.State.Running}}' 2>/dev/null)" != "true" ]]; then
    echo ">> Starting database (ac-database) on volume '$DB_VOLUME'"
    podman run -d --name ac-database --replace \
      --network "$NETWORK" \
      -e MYSQL_ROOT_PASSWORD="$DB_PASS" \
      -v "$DB_VOLUME":/var/lib/mysql \
      --health-cmd="mysqladmin ping -uroot -p$DB_PASS" \
      --health-interval=5s --health-timeout=10s --health-retries=40 \
      "$DB_IMAGE" >/dev/null
  fi
  echo -n ">> Waiting for database to be healthy"
  until [[ "$(podman inspect ac-database --format '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]]; do
    echo -n "."; sleep 3
  done
  echo " ok"
  # make sure the four databases exist (AutoSetup then imports/updates them)
  podman exec ac-database mysql -uroot -p"$DB_PASS" -e "
    CREATE DATABASE IF NOT EXISTS acore_auth       DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_general_ci;
    CREATE DATABASE IF NOT EXISTS acore_world      DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_general_ci;
    CREATE DATABASE IF NOT EXISTS acore_characters DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_general_ci;
    CREATE DATABASE IF NOT EXISTS acore_playerbots DEFAULT CHARSET utf8mb4 COLLATE utf8mb4_general_ci;" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_compile() {
  ensure_image
  echo ">> Compiling: acore.sh compiler $*"
  exec podman run --rm --name ac-dev-build \
    --userns="keep-id:uid=${UID_N},gid=${GID_N}" \
    --security-opt label=disable \
    -v "$REPO_ROOT:/azerothcore" \
    "$IMAGE" \
    bash /azerothcore/acore.sh compiler "$@"
}

cmd_up() {
  if [[ ! -x "$REPO_ROOT/env/dist/bin/worldserver" ]]; then
    echo "!! env/dist/bin/worldserver not found - build first: $0 build" >&2
    exit 1
  fi
  ensure_image
  ensure_network
  ensure_database

  # the DB updater writes a temp mysql defaults file under AC_TEMP_DIR; these live
  # on the bind-mounted host repo, so make sure they exist before the server starts
  mkdir -p "$REPO_ROOT/env/dist/temp" "$REPO_ROOT/env/dist/logs"

  mapfile -d '' -t SENV < <(server_env)

  echo ">> Starting authserver (host port ${AUTH_PORT} -> 3724)"
  podman run -d --name ac-authserver --replace \
    --userns="keep-id:uid=${UID_N},gid=${GID_N}" --security-opt label=disable \
    --network "$NETWORK" "${SENV[@]}" \
    -p "${AUTH_PORT}:3724" \
    -w /azerothcore/env/dist/bin \
    -v "$REPO_ROOT:/azerothcore" \
    "$IMAGE" ./authserver -c /azerothcore/env/dist/etc/authserver.conf >/dev/null

  echo ">> Starting worldserver (host ports ${WORLD_PORT} -> 8085, ${SOAP_PORT} -> 7878)"
  # -i keeps stdin open so 'console' / 'account' can drive the worldserver console
  podman run -d -i --name ac-worldserver --replace \
    --userns="keep-id:uid=${UID_N},gid=${GID_N}" --security-opt label=disable \
    --network "$NETWORK" "${SENV[@]}" \
    -p "${WORLD_PORT}:8085" -p "${SOAP_PORT}:7878" \
    -w /azerothcore/env/dist/bin \
    -v "$REPO_ROOT:/azerothcore" \
    -v "$CLIENT_DATA_VOLUME":/azerothcore/env/dist/data:ro \
    "$IMAGE" ./worldserver -c /azerothcore/env/dist/etc/worldserver.conf >/dev/null

  echo -n ">> Waiting for world to initialize (first run imports the DB, can take minutes)"
  until podman logs ac-worldserver 2>&1 | grep -qi "World Initialized In"; do
    if [[ "$(podman inspect ac-worldserver --format '{{.State.Running}}' 2>/dev/null)" != "true" ]]; then
      echo; echo "!! worldserver exited during startup - see: $0 logs world" >&2; exit 1
    fi
    echo -n "."; sleep 5
  done
  echo " ready"
  cmd_status
  echo ">> Console:  $0 console        Create account:  $0 account <user> <pass>"
}

cmd_down() {
  podman rm -f ac-worldserver ac-authserver >/dev/null 2>&1 || true
  echo ">> Stopped authserver + worldserver"
  if [[ "${1:-}" == "--all" ]]; then
    podman rm -f ac-database >/dev/null 2>&1 || true
    echo ">> Stopped database (volume '$DB_VOLUME' preserved)"
  fi
}

cmd_status() {
  echo ">> Containers:"
  podman ps --filter name=ac-database --filter name=ac-authserver --filter name=ac-worldserver \
    --format '   {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
}

cmd_logs() {
  case "${1:-world}" in
    world) podman logs -f ac-worldserver ;;
    auth)  podman logs -f ac-authserver ;;
    db)    podman logs -f ac-database ;;
    *) echo "logs target must be world|auth|db" >&2; exit 1 ;;
  esac
}

cmd_console() {
  echo ">> Attaching to worldserver console. Detach with Ctrl-P Ctrl-Q (do NOT Ctrl-C)."
  exec podman attach ac-worldserver
}

cmd_account() {
  local user="${1:?usage: account <user> <pass> [gmlevel]}"
  local pass="${2:?usage: account <user> <pass> [gmlevel]}"
  local gm="${3:-3}"
  if [[ "$(podman inspect ac-worldserver --format '{{.State.Running}}' 2>/dev/null)" != "true" ]]; then
    echo "!! worldserver is not running - start it first: $0 up" >&2; exit 1
  fi
  local fifo; fifo="$(mktemp -u)"; mkfifo "$fifo"
  exec 9<>"$fifo"                      # hold FIFO open so the console never sees EOF
  podman attach ac-worldserver <"$fifo" >/dev/null 2>&1 &
  local apid=$!
  sleep 2
  printf 'account create %s %s\n' "$user" "$pass" >&9
  sleep 4
  printf 'account set gmlevel %s %s -1\n' "$user" "$gm" >&9
  sleep 4
  # Ctrl-P Ctrl-Q: detach cleanly so the worldserver keeps running.
  # (Killing the attach would close the console stdin and shut the server down.)
  printf '\020\021' >&9
  sleep 1
  exec 9>&-
  wait "$apid" 2>/dev/null || true
  rm -f "$fifo"
  echo ">> Account '$user' created (gmlevel $gm)."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

case "${1:-build}" in
  up)                 shift; cmd_up "$@" ;;
  down)               shift; cmd_down "$@" ;;
  status)             cmd_status ;;
  logs)               shift; cmd_logs "$@" ;;
  console)            cmd_console ;;
  account)            shift; cmd_account "$@" ;;
  build|all|clean|configure|compile|ccacheClean|ccacheShowStats)
                      cmd_compile "$@" ;;
  *)                  echo "unknown command '$1' - see header for usage" >&2; exit 1 ;;
esac
