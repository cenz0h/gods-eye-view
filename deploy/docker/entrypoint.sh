#!/bin/sh
# God's Eye View container entrypoint.
# 1. (root only) align the `node` user with PUID/PGID and fix volume ownership
# 2. build dist/ if missing, forced, or if the build stamp changed
#    (stamp = image build id + the two client keys frozen into the bundle)
# 3. exec `vite preview` as the unprivileged user
set -eu

APP_DIR=/app
DIST_DIR="$APP_DIR/dist"
STAMP_FILE="$DIST_DIR/.gev-build-stamp"
VITE="$APP_DIR/node_modules/vite/bin/vite.js"
PORT="${PORT:-4173}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

log()  { printf '[gev] %s\n' "$*"; }
warn() { printf '[gev] WARNING: %s\n' "$*" >&2; }
die()  { printf '[gev] ERROR: %s\n' "$*" >&2; exit 1; }

cd "$APP_DIR"
[ -f "$VITE" ] || die "vite not found at $VITE (image is broken)"

# ---------------------------------------------------------------- config file
# Keys typed into a container manager's UI live in that manager's own config.
# On Unraid they sit in the user template on the flash drive, and re-applying
# or reinstalling the template resets every field to the template's defaults,
# which are deliberately blank for secrets. Reading them from a file in a
# mounted volume instead makes them independent of the container's definition:
# recreating, updating or reinstalling the container cannot touch them.
#
# Precedence matches the app's own (server/standalone/vite.config.js): a real
# environment variable wins, and the file fills the gaps. A variable that is
# present but EMPTY counts as unset, because a container manager passes blank
# fields through as empty strings and those must not shadow the file.
GEV_ENV_FILE="${GEV_ENV_FILE:-/config/gev.env}"

load_env_file() {
  file="$1"
  [ -f "$file" ] || return 0

  # Strip CR first: these files get edited on Windows, and a trailing CR ends
  # up inside the value, which breaks key comparisons in confusing ways.
  # Read from a temp file rather than a pipe so exports survive (a pipe would
  # run the loop in a subshell).
  tmp="$(mktemp)"
  tr -d '\r' < "$file" > "$tmp"

  loaded=''
  skipped=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    line="${line#export }"
    key="${line%%=*}"
    [ "$key" = "$line" ] && continue
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    case "$key" in '' | *[!A-Za-z0-9_]*) continue ;; esac

    value="${line#*=}"
    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac

    eval "current=\${$key:-}"
    if [ -n "${current:-}" ]; then
      skipped="$skipped $key"
    else
      export "$key=$value"
      loaded="$loaded $key"
    fi
  done < "$tmp"
  rm -f "$tmp"

  # Names only. Never log a value.
  [ -z "$loaded" ] || log "config file set:$loaded"
  [ -z "$skipped" ] || log "config file overridden by the environment:$skipped"
}

# Seed an annotated file the first time the volume is mounted, so there is
# something obvious to edit rather than an empty directory.
seed_env_file() {
  dir="$(dirname "$GEV_ENV_FILE")"
  [ -d "$dir" ] || return 0
  [ -e "$GEV_ENV_FILE" ] && return 0
  cat > "$GEV_ENV_FILE" <<'SEED' || return 0
# God's Eye View configuration.
#
# Keys here survive container updates, recreation and template changes, which
# values typed into a container manager's UI may not. One KEY=value per line.
# Anything already set in the container's environment wins over this file.
#
# Changing either of the two client keys rebuilds the web bundle on the next
# start (1-5 minutes). The rest take effect on restart.
#
# Full reference: https://github.com/cenz0h/gods-eye-view/blob/docker/.env.example
# Billing warning before you set a Google key: deploy/docker/README.md

# GOOGLE_MAPS_API_KEY=
# CESIUM_ION_TOKEN=
# OPENAI_API_KEY=
# OPENSKY_CLIENT_ID=
# OPENSKY_CLIENT_SECRET=
# AISSTREAM_API_KEY=
# TOMTOM_API_KEY=
# FIRMS_MAP_KEY=
SEED
  # Owned by the runtime user so it stays editable over a share, and 0600
  # because it is about to hold secrets. Only ever applied to a file this
  # script just created — an existing one belongs to whoever set it up.
  if [ "$(id -u)" = "0" ]; then
    chown "$PUID:$PGID" "$GEV_ENV_FILE" 2>/dev/null || true
  fi
  chmod 600 "$GEV_ENV_FILE" 2>/dev/null || true
  log "created $GEV_ENV_FILE — put your API keys there"
}

seed_env_file
load_env_file "$GEV_ENV_FILE"

# ---------------------------------------------------------------- privileges
RUN_AS=""
if [ "$(id -u)" = "0" ]; then
  case "$PUID$PGID" in *[!0-9]*) die "PUID/PGID must be numeric (got PUID=$PUID PGID=$PGID)";; esac
  if [ "$(id -g node)" != "$PGID" ]; then groupmod -o -g "$PGID" node; fi
  if [ "$(id -u node)" != "$PUID" ]; then usermod  -o -u "$PUID" node; fi
  # /app itself must be writable: vite bundles the config to a temp file next to vite.config.js
  # before both `build` and `preview`. Non-recursive on purpose — a recursive chown would walk
  # node_modules (~400 MB) on every container creation for no benefit.
  if [ "$(stat -c '%u:%g' "$APP_DIR")" != "$PUID:$PGID" ]; then
    log "chown $APP_DIR (top level only) -> $PUID:$PGID"
    chown "$PUID:$PGID" "$APP_DIR"
  fi
  for d in "$DIST_DIR" "$APP_DIR/.gev-cache" "$APP_DIR/.gev-logs" "$APP_DIR/node_modules/.vite" /home/node; do
    mkdir -p "$d"
    if [ "$(stat -c '%u:%g' "$d")" != "$PUID:$PGID" ]; then
      log "chown $d -> $PUID:$PGID"
      chown -R "$PUID:$PGID" "$d"
    fi
  done
  RUN_AS="setpriv --reuid=$PUID --regid=$PGID --clear-groups"
  export HOME=/home/node
  log "running as uid=$PUID gid=$PGID"
else
  log "started as uid=$(id -u) (not root): skipping PUID/PGID handling"
  for d in "$DIST_DIR" "$APP_DIR/.gev-cache" "$APP_DIR/.gev-logs"; do
    [ -w "$d" ] || warn "$d is not writable by uid $(id -u); expect build/cache failures"
  done
fi

# ---------------------------------------------------------------- build stamp
# Hash ONLY what Vite freezes into the browser bundle: build/vite.js `define`s
# GOOGLE_MAPS_API_KEY and CESIUM_ION_TOKEN, and Vite itself exposes VITE_* vars. Every other key
# (OPENAI_API_KEY, OPENSKY_*, TOMTOM_API_KEY, ...) is read at request time, so changing one must
# NOT trigger a pointless rebuild.
#
# The stamp lives in dist/ and vite preview serves it. That is safe precisely because it only
# covers values that are already public in dist/assets/*.js — never a server-side secret.
#
# server/standalone/vite.config.js gives real environment variables precedence over /app/.env,
# so look them up in that order.
env_file_lookup() {
  [ -f "$APP_DIR/.env" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$APP_DIR/.env" \
    | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
baked_value() {
  eval "_v=\${$1:-}"
  [ -n "${_v:-}" ] || _v="$(env_file_lookup "$1")"
  printf '%s=%s\n' "$1" "${_v:-}"
}
compute_stamp() {
  {
    printf 'gev-stamp-v2\nbuild_id=%s\n' "${GEV_BUILD_ID:-dev}"
    baked_value GOOGLE_MAPS_API_KEY
    baked_value CESIUM_ION_TOKEN
    {
      env | grep '^VITE_[A-Za-z0-9_]*=' || true
      if [ -f "$APP_DIR/.env" ]; then
        grep -E '^[[:space:]]*VITE_[A-Za-z0-9_]+=' "$APP_DIR/.env" | sed 's/^[[:space:]]*//' || true
      fi
    } | LC_ALL=C sort -u
  } | sha256sum | cut -d' ' -f1
}
STAMP="$(compute_stamp)"

reason=""
if   [ "${GEV_FORCE_REBUILD:-0}" = "1" ];     then reason="GEV_FORCE_REBUILD=1"
elif [ ! -f "$DIST_DIR/index.html" ];         then reason="dist/index.html missing (first start or empty volume)"
elif [ ! -f "$STAMP_FILE" ];                  then reason="no build stamp in dist/"
elif [ "$(cat "$STAMP_FILE")" != "$STAMP" ];  then reason="build stamp changed (new image or client map keys changed)"
fi

[ -n "${GOOGLE_MAPS_API_KEY:-}" ] || warn "GOOGLE_MAPS_API_KEY is empty: Google Photorealistic 3D Tiles will be unavailable"
[ -n "${CESIUM_ION_TOKEN:-}" ]    || warn "CESIUM_ION_TOKEN is empty: Cesium ion imagery/terrain will be unavailable"

if [ -n "$reason" ]; then
  log "building client bundle: $reason"
  log "image build id: ${GEV_BUILD_ID:-dev}"
  rm -f "$STAMP_FILE"
  start=$(date +%s)
  # shellcheck disable=SC2086
  $RUN_AS env NODE_OPTIONS="${GEV_BUILD_NODE_OPTIONS:---max-old-space-size=2048}" \
    node "$VITE" build --logLevel "${GEV_BUILD_LOG_LEVEL:-info}" \
    || die "vite build failed; not starting the server"
  printf '%s\n' "$STAMP" > "$STAMP_FILE"
  [ -z "$RUN_AS" ] || chown "$PUID:$PGID" "$STAMP_FILE"
  log "build complete in $(( $(date +%s) - start ))s"
else
  log "reusing client bundle in $DIST_DIR (stamp $STAMP matches)"
fi

# ---------------------------------------------------------------- serve
# HOST=0.0.0.0 (image ENV) is what makes build/vite.js set allowedHosts=true; the CLI flag alone
# would not. Do not override HOST.
[ "${HOST:-}" = "0.0.0.0" ] || [ "${HOST:-}" = "::" ] || warn "HOST=${HOST:-} : proxied requests will be rejected by Vite's allowedHosts check"
log "starting vite preview on 0.0.0.0:$PORT"
# shellcheck disable=SC2086
exec $RUN_AS node "$VITE" preview --host 0.0.0.0 --port "$PORT" --strictPort
