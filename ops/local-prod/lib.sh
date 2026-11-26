#!/usr/bin/env bash
# Shared settings and helpers for ops/local-prod. Sourced, never run.
# Nothing here prints a secret or puts one on a command line: keys and
# passwords stay in mode-600 files and reach processes through the environment.

set -euo pipefail

LP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LP_DIR/../.." && pwd)"
API_DIR="$REPO_DIR/api"
WEB_DIR="$REPO_DIR/web"

# Everything the mirror owns lives here: database, Redis, logs, pids, certs,
# captured mail, stored files and built web surfaces.
STATE="${LOCAL_PROD_HOME:-$HOME/.local/share/cornerstone-local-prod}"
STATE_MARKER=".cornerstone-local-prod"
CLERK_ENV_FILE="${LOCAL_PROD_CLERK_ENV:-$HOME/.config/shimizu/clerk-payroll-local.env}"

ROOT_DOMAIN="cornerstone.localhost"
HTTPS_PORT=8443
PG_PORT=55432
REDIS_PORT=56379
STAFF_PORT=3110
EMPLOYEE_PORT=3111
CADDY_ADMIN_PORT=2099
CADDY_ADMIN="127.0.0.1:$CADDY_ADMIN_PORT"
PG_BIN="${LOCAL_PROD_PG_BIN:-/opt/homebrew/opt/postgresql@16/bin}"
DB_NAME="cornerstone_payroll"
DB_OWNER="cornerstone_owner"

STAFF_ORIGIN="https://payroll.$ROOT_DOMAIN:$HTTPS_PORT"
API_ORIGIN="https://api.$ROOT_DOMAIN:$HTTPS_PORT"
EMPLOYEE_API_ORIGIN="https://employee-api.$ROOT_DOMAIN:$HTTPS_PORT"
TENANT_HOSTS=(harborfinch harborfinch-catering)

RUN="$STATE/run"
LOGS="$STATE/logs"
ENVS="$STATE/env"
SECRETS="$STATE/secrets.env"
PGPASS="$STATE/pgpass"

log() { printf '[local-prod] %s\n' "$*"; }
warn() { printf '[local-prod] WARN %s\n' "$*" >&2; }
die() { printf '[local-prod] FAIL %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  for tool in "$PG_BIN/initdb" "$PG_BIN/pg_ctl" "$PG_BIN/psql" redis-server redis-cli caddy mkcert node npm bundle python3 curl lsof shasum; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (brew install postgresql@16 redis caddy mkcert node)"
  [[ -r "$CLERK_ENV_FILE" ]] || die "missing Clerk development keys file $CLERK_ENV_FILE"
}

ensure_dirs() {
  umask 077
  mkdir -p "$STATE" "$RUN" "$LOGS" "$ENVS" "$STATE/pg/run" "$STATE/redis" "$STATE/certs" "$STATE/mail" "$STATE/storage" "$STATE/web"
  chmod 700 "$STATE"
  # down.sh --purge deletes only a directory carrying this marker.
  [[ -f "$STATE/$STATE_MARKER" ]] || echo "Cornerstone Payroll local production copy (ops/local-prod)" >"$STATE/$STATE_MARKER"
}

# A minimal, explicit environment: a caller's PG*, CI or Render settings never
# reach the app (local mode refuses to boot with them anyway).
clean_env() {
  env -i HOME="$HOME" USER="${USER:-}" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
    ${RBENV_VERSION:+RBENV_VERSION="$RBENV_VERSION"} "$@"
}

# Run a command with one generated env file loaded (values never on argv).
with_env() {
  local file="$1"; shift
  clean_env bash -c 'set -a; . "$1"; set +a; shift; exec "$@"' _ "$file" "$@"
}

# What each service's command line must contain, so a stale pid file that a
# later, unrelated process reused is never signalled.
service_pattern() {
  case "$1" in
    staff) echo "puma.*127\\.0\\.0\\.1:$STAFF_PORT" ;;
    employee) echo "puma.*127\\.0\\.0\\.1:$EMPLOYEE_PORT" ;;
    worker) echo "bin/jobs|solid-queue-(fork-)?supervisor" ;;
    caddy) echo "caddy .*$STATE/Caddyfile" ;;
    redis) echo "redis-server 127\\.0\\.0\\.1:$REDIS_PORT" ;;
    postgres) echo "postgres.*-D $STATE/pg/data" ;;
    *) die "unknown service $1" ;;
  esac
}

pid_file() {
  [[ "$1" == postgres ]] && echo "$STATE/pg/data/postmaster.pid" || echo "$RUN/$1.pid"
}

# Prints the service's live pid, or nothing. A pid file that isn't a positive
# integer, or whose process isn't that service, is reported and removed.
service_pid() {
  local name="$1" file pid command
  file="$(pid_file "$name")"
  [[ -f "$file" ]] || return 0
  pid="$(head -1 "$file" | tr -d '[:space:]')"
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    warn "ignoring $name pid file with an invalid pid"; [[ "$name" == postgres ]] || rm -f "$file"; return 0
  fi
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$command" ]] || { [[ "$name" == postgres ]] || rm -f "$file"; return 0; }
  local ours=true
  grep -qE "$(service_pattern "$name")" <<<"$command" || ours=false
  # Rails processes must also run from this checkout's api/ directory.
  if $ours && [[ "$name" == staff || "$name" == employee || "$name" == worker ]]; then
    local cwd; cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [[ "$cwd" == "$(cd "$API_DIR" && pwd -P)" ]] || ours=false
  fi
  if ! $ours; then
    warn "pid $pid in the $name pid file belongs to another process; leaving it alone"
    [[ "$name" == postgres ]] || rm -f "$file"
    return 0
  fi
  echo "$pid"
}

service_alive() { [[ -n "$(service_pid "$1")" ]]; }

# Fails when anything else already listens on a loopback port we need.
require_free_port() {
  local port="$1" what="$2" holder
  holder="$(lsof -nP -t "-iTCP@127.0.0.1:$port" "-iTCP@[::1]:$port" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
  [[ -z "$holder" ]] || die "port $port ($what) is already in use by pid $holder; stop it or change the port in lib.sh"
}

claim() {
  # Register a started process with dev-lifecycle when an agent session is set.
  # It declines postgres and redis-server by design; their validated pid files
  # and down.sh cover those two.
  local pid="$1" reason="$2"
  if [[ -n "${DEV_LIFECYCLE_SESSION:-}" ]] && command -v dev-lifecycle >/dev/null 2>&1; then
    dev-lifecycle claim --session "$DEV_LIFECYCLE_SESSION" --owner local-prod --reason "$reason" process "$pid" >/dev/null 2>&1 || true
  fi
}

release() {
  if [[ -n "${DEV_LIFECYCLE_SESSION:-}" ]] && command -v dev-lifecycle >/dev/null 2>&1; then
    dev-lifecycle release --session "$DEV_LIFECYCLE_SESSION" process "$1" >/dev/null 2>&1 || true
  fi
}

# Superuser SQL through the private socket only, to the maintenance database.
psql_super() {
  clean_env "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse -h "$STATE/pg/run" -p "$PG_PORT" -U postgres -d postgres "$@"
}

# Owner SQL over TCP; the password comes from the mode-600 pgpass file.
owner_psql() {
  clean_env PGPASSFILE="$PGPASS" "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -v VERBOSITY=terse \
    -h 127.0.0.1 -p "$PG_PORT" -U "$DB_OWNER" -d "$DB_NAME" "$@"
}

# Polls a check; with a service name, also fails as soon as that service dies.
wait_for() {
  local what="$1" tries="$2" service="$3"; shift 3
  for ((i = 0; i < tries; i++)); do
    if [[ -n "$service" ]] && ! service_alive "$service"; then die "$what exited while starting (see $LOGS)"; fi
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "$what did not come up (see $LOGS)"
}

curl_local() { clean_env curl -fsS --max-time 10 --cacert "$STATE/certs/ca-bundle.pem" "$@"; }
