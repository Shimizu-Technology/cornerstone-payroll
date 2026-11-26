#!/usr/bin/env bash
# Shared settings and helpers for ops/local-prod. Sourced, never run.
# Nothing here prints a secret: keys and passwords stay in files with mode 600.

set -euo pipefail

LP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$LP_DIR/../.." && pwd)"
API_DIR="$REPO_DIR/api"
WEB_DIR="$REPO_DIR/web"

# Everything the mirror owns lives here: database, Redis, logs, pids, certs,
# captured mail, stored files and built web surfaces.
STATE="${LOCAL_PROD_HOME:-$HOME/.local/share/cornerstone-local-prod}"
CLERK_ENV_FILE="${LOCAL_PROD_CLERK_ENV:-$HOME/.config/shimizu/clerk-payroll-local.env}"

ROOT_DOMAIN="cornerstone.localhost"
HTTPS_PORT=8443
PG_PORT=55432
REDIS_PORT=56379
STAFF_PORT=3110
EMPLOYEE_PORT=3111
CADDY_ADMIN="127.0.0.1:2099"
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

log() { printf '[local-prod] %s\n' "$*"; }
die() { printf '[local-prod] FAIL %s\n' "$*" >&2; exit 1; }

require_tools() {
  local missing=()
  for tool in "$PG_BIN/initdb" "$PG_BIN/pg_ctl" "$PG_BIN/psql" redis-server redis-cli caddy mkcert node npm bundle python3 curl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]} (brew install postgresql@16 redis caddy mkcert node)"
  [[ -r "$CLERK_ENV_FILE" ]] || die "missing Clerk development keys file $CLERK_ENV_FILE"
}

ensure_dirs() {
  umask 077
  mkdir -p "$STATE" "$RUN" "$LOGS" "$ENVS" "$STATE/pg/run" "$STATE/redis" "$STATE/certs" "$STATE/mail" "$STATE/storage" "$STATE/web"
  chmod 700 "$STATE"
}

# A minimal, explicit environment: a caller's PG*, CI or Render settings never
# reach the app (local mode refuses to boot with them anyway).
clean_env() {
  env -i HOME="$HOME" USER="${USER:-}" PATH="$PATH" LANG="${LANG:-en_US.UTF-8}" TMPDIR="${TMPDIR:-/tmp}" \
    ${RBENV_VERSION:+RBENV_VERSION="$RBENV_VERSION"} "$@"
}

# Run a command with one generated env file loaded.
with_env() {
  local file="$1"; shift
  clean_env bash -c 'set -a; . "$1"; set +a; shift; exec "$@"' _ "$file" "$@"
}

pid_alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }

claim() {
  # Register a started process with dev-lifecycle when an agent session is set.
  # It declines postgres and redis-server by design; the pid files and
  # down.sh cover those two.
  local pid="$1" reason="$2"
  if [[ -n "${DEV_LIFECYCLE_SESSION:-}" ]] && command -v dev-lifecycle >/dev/null 2>&1; then
    dev-lifecycle claim --session "$DEV_LIFECYCLE_SESSION" --owner local-prod --reason "$reason" process "$pid" >/dev/null 2>&1 || true
  fi
}

psql_super() { "$PG_BIN/psql" -X -q -v ON_ERROR_STOP=1 -h "$STATE/pg/run" -p "$PG_PORT" -U postgres "$@"; }

wait_for() {
  local what="$1" tries="$2"; shift 2
  for ((i = 0; i < tries; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "$what did not come up (see $LOGS)"
}
