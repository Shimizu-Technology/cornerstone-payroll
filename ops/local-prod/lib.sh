#!/usr/bin/env bash
# Shared settings and helpers for ops/local-prod. Sourced, never run.
# Nothing here prints a secret or puts one on a command line: keys and
# passwords stay in mode-600 files and reach processes through the environment.

set -euo pipefail

LP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LP_DIR/../.." && pwd -P)"
API_DIR="$REPO_DIR/api"
WEB_DIR="$REPO_DIR/web"

log() { printf '[local-prod] %s\n' "$*"; }
warn() { printf '[local-prod] WARN %s\n' "$*" >&2; }
die() { printf '[local-prod] FAIL %s\n' "$*" >&2; exit 1; }

# Everything the mirror owns lives in one directory: database, Redis, logs,
# pids, certs, captured mail, stored files and built web surfaces. Its path is
# normalised once (no trailing slash, real parent directory), so every check
# and every process command line uses the same spelling.
normalize_state() {
  local raw="${LOCAL_PROD_HOME:-$HOME/.local/share/cornerstone-local-prod}" parent
  [[ "$raw" == /* ]] || die "LOCAL_PROD_HOME must be an absolute path"
  while [[ "$raw" == */ && "$raw" != / ]]; do raw="${raw%/}"; done
  [[ "$raw" != / ]] || die "refusing / as the local-prod data directory"
  parent="$(dirname "$raw")"
  [[ -d "$parent" ]] && parent="$(cd "$parent" && pwd -P)"
  STATE="${parent%/}/$(basename "$raw")"
}
normalize_state
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

require_tools() {
  local missing=()
  for tool in "$PG_BIN/initdb" "$PG_BIN/pg_ctl" "$PG_BIN/psql" redis-server redis-cli caddy mkcert node npm bundle python3 curl lsof shasum; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (brew install postgresql@16 redis caddy mkcert node)"
  [[ -r "$CLERK_ENV_FILE" ]] || die "missing Clerk development keys file $CLERK_ENV_FILE"
}

real_dir() { [[ -d "$1" ]] && (cd "$1" && pwd -P) || printf '%s' "$1"; }

# The one rule for the data directory, used before creating it and before
# deleting it: never a shared or top-level directory, never a symlink, never
# a directory holding this repository.
check_state_path() {
  local target="$STATE" repo bad
  [[ ! -L "$target" ]] || die "refusing $target: it is a symlink"
  [[ ! -L "$target/$STATE_MARKER" ]] || die "refusing $target: its marker is a symlink"
  [[ -e "$target" ]] && target="$(real_dir "$target")"
  for bad in / /Users /tmp /private/tmp /var /private/var "${TMPDIR:-/tmp}" "$HOME" "$HOME/.local" "$HOME/.local/share" \
      "$HOME/.config" "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME/Library"; do
    [[ "$target" != "$(real_dir "${bad%/}")" ]] || die "refusing $target as the local-prod data directory"
  done
  repo="$REPO_DIR"
  [[ "$repo" != "$target" && "$repo" != "$target"/* ]] || die "refusing $target: it contains this repository"
}

# STATE must be a directory this script created (missing or empty) or one
# that already carries the marker. An existing directory is never adopted.
ensure_dirs() {
  umask 077
  check_state_path
  if [[ -e "$STATE" ]]; then
    [[ -d "$STATE" ]] || die "refusing $STATE: it is not a directory"
    if [[ ! -f "$STATE/$STATE_MARKER" && -n "$(ls -A "$STATE")" ]]; then
      die "refusing $STATE: it is not empty and has no $STATE_MARKER marker; choose another LOCAL_PROD_HOME"
    fi
  fi
  mkdir -p "$STATE"
  [[ -f "$STATE/$STATE_MARKER" ]] || echo "Cornerstone Payroll local production copy (ops/local-prod)" >"$STATE/$STATE_MARKER"
  mkdir -p "$RUN" "$LOGS" "$ENVS" "$STATE/pg/run" "$STATE/redis" "$STATE/certs" "$STATE/mail" "$STATE/storage" "$STATE/web"
  chmod 700 "$STATE"
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

pid_file() {
  [[ "$1" == postgres ]] && echo "$STATE/pg/data/postmaster.pid" || echo "$RUN/$1.pid"
}

process_cwd() { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true; }

# Whether pid is this mirror's service. Paths are compared as fixed strings;
# ports must end at a non-digit; Rails processes must run from this checkout
# with this mirror's environment.
is_our_service() {
  local name="$1" pid="$2" command
  command="$(ps -ww -p "$pid" -o command= 2>/dev/null || true)"
  [[ -n "$command" ]] || return 1
  case "$name" in
    staff | employee)
      local port="$STAFF_PORT"; [[ "$name" == employee ]] && port="$EMPLOYEE_PORT"
      [[ "$command" =~ puma && "$command" =~ 127\.0\.0\.1:$port([^0-9]|$) ]] || return 1 ;;
    worker) [[ "$command" =~ bin/jobs|solid-queue-(fork-)?supervisor ]] || return 1 ;;
    caddy) [[ "$command" == *caddy* && "$command" == *"$STATE/Caddyfile"* ]] || return 1 ;;
    redis)
      [[ "$command" =~ redis-server\ 127\.0\.0\.1:$REDIS_PORT([^0-9]|$) ]] || return 1
      [[ "$(process_cwd "$pid")" == "$STATE/redis" ]] || return 1 ;;
    postgres) [[ "$command" == *postgres* && "$command" == *"-D $STATE/pg/data"* ]] || return 1 ;;
    *) die "unknown service $name" ;;
  esac
  if [[ "$name" == staff || "$name" == employee || "$name" == worker ]]; then
    [[ "$(process_cwd "$pid")" == "$API_DIR" ]] || return 1
    # Its standard output is this mirror's log for the service (start_rails
    # opens it before launch), which survives Puma renaming its process title.
    local stdout; stdout="$(lsof -a -p "$pid" -d 1 -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)"
    [[ "$stdout" == "$LOGS/$name.log" ]] || return 1
  fi
  return 0
}

# Prints the service's live pid, or nothing. A pid file that isn't a positive
# integer, or whose process isn't that service, is reported and removed.
service_pid() {
  local name="$1" file pid
  file="$(pid_file "$name")"
  [[ -f "$file" ]] || return 0
  pid="$(head -1 "$file" | tr -d '[:space:]')"
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]]; then
    warn "ignoring $name pid file with an invalid pid"; [[ "$name" == postgres ]] || rm -f "$file"; return 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    [[ "$name" == postgres ]] || rm -f "$file"; return 0
  fi
  if ! is_our_service "$name" "$pid"; then
    warn "pid $pid in the $name pid file belongs to another process; leaving it alone"
    [[ "$name" == postgres ]] || rm -f "$file"
    return 0
  fi
  echo "$pid"
}

service_alive() { [[ -n "$(service_pid "$1")" ]]; }

port_holder() {
  lsof -nP -t "-iTCP@127.0.0.1:$1" "-iTCP@[::1]:$1" -sTCP:LISTEN 2>/dev/null | head -1 || true
}

# Fails when anything else already listens on a loopback port we need.
require_free_port() {
  local holder; holder="$(port_holder "$1")"
  [[ -z "$holder" ]] || die "port $1 ($2) is already in use by pid $holder; stop it or change the port in lib.sh"
}

claim() {
  # Register a started process with dev-lifecycle when an agent session is set.
  # It declines postgres and redis-server by design; their validated pid files
  # and down.sh cover those two.
  local pid="$1" reason="$2"
  if [[ -n "${DEV_LIFECYCLE_SESSION:-}" ]] && command -v dev-lifecycle >/dev/null 2>&1; then
    dev-lifecycle claim --session "$DEV_LIFECYCLE_SESSION" --owner local-prod --reason "$reason" process "$pid" >/dev/null 2>&1 && return 0
    [[ "$reason" == *postgres* || "$reason" == *redis* ]] || warn "dev-lifecycle did not claim pid $pid ($reason); claim it by hand"
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
