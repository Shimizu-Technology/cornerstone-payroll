#!/usr/bin/env bash
# Automated OWASP ZAP passive baseline scan for the employee web surface and
# employee API (M4-11).
#
# Usage:
#   # Local build + local employee_web API (default, used in CI):
#   bash scripts/security/zap_baseline_employee.sh --mode local --output-dir tmp/zap-reports
#
#   # Pre-invite production scan (passive only, never active attack):
#   bash scripts/security/zap_baseline_employee.sh --mode production \
#     --web-url https://mosas.shimizu-technology.com \
#     --api-url https://cornerstone-payroll-employee-api.onrender.com \
#     --output-dir tmp/zap-reports-prod
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODE="local"
OUTPUT_DIR="${ROOT_DIR}/tmp/zap-reports"
WEB_URL=""
API_URL=""
# Pinned OCI index digest of ghcr.io/zaproxy/zaproxy:stable (verified 2026-11-25).
ZAP_IMAGE="${ZAP_IMAGE:-ghcr.io/zaproxy/zaproxy@sha256:9624669db72f54d86c4b46a7064518bd9bf79d8c61a4c31befa9923489f328af}"
WEB_PORT="${ZAP_WEB_PORT:-4173}"
API_PORT="${ZAP_API_PORT:-3011}"
SKIP_BUILD="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --web-url) WEB_URL="$2"; shift 2 ;;
    --api-url) API_URL="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD="true"; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [[ "$MODE" != "local" && "$MODE" != "production" ]]; then
  echo "Invalid --mode '$MODE' (expected 'local' or 'production')" >&2
  exit 2
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is required to run OWASP ZAP (${ZAP_IMAGE})." >&2
  exit 1
fi

# Reject symlink, non-owned, or world-writable output directories before writing
# server logs or scan reports there (an earlier harness version left 0777 dirs).
validate_output_dir() {
  local dir="$1"
  if [[ -L "$dir" ]]; then
    echo "Refusing symlink --output-dir: ${dir}" >&2
    exit 1
  fi
  mkdir -p -m 0755 "$dir"
  if [[ ! -d "$dir" || -L "$dir" ]]; then
    echo "Invalid --output-dir: ${dir}" >&2
    exit 1
  fi
  if [[ ! -O "$dir" ]]; then
    echo "Refusing --output-dir not owned by current user: ${dir}" >&2
    exit 1
  fi
  local perm
  if stat -c '%a' "$dir" >/dev/null 2>&1; then
    perm="$(stat -c '%a' "$dir")"
  else
    perm="$(stat -f '%Lp' "$dir")"
  fi
  if (( (8#$perm & 8#0002) != 0 )); then
    echo "Refusing world-writable --output-dir (mode ${perm}): ${dir}" >&2
    exit 1
  fi
}

# Copy a regular file into OUTPUT_DIR without following source or destination
# symlinks (stages via mktemp in OUTPUT_DIR and atomically renames into place).
safe_copy_file() {
  local src="$1"
  local dest="$2"
  if [[ ! -f "$src" || -L "$src" ]]; then
    echo "Refusing to copy non-regular or symlink source: ${src}" >&2
    return 1
  fi
  if [[ -L "$dest" || -d "$dest" ]]; then
    echo "Refusing to overwrite destination symlink or directory: ${dest}" >&2
    return 1
  fi
  local tmp_dest
  tmp_dest="$(mktemp "${OUTPUT_DIR}/.$(basename "$dest").XXXXXX")"
  chmod 0644 "$tmp_dest"
  if ! cat "$src" >"$tmp_dest" || ! mv -f "$tmp_dest" "$dest"; then
    rm -f "$tmp_dest"
    return 1
  fi
}

require_non_symlink_path() {
  local path="$1"
  if [[ -L "$path" ]]; then
    echo "Refusing symlink destination: ${path}" >&2
    exit 1
  fi
}

validate_output_dir "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
validate_output_dir "$OUTPUT_DIR"

# The ZAP container runs as the `zap` user (UID 1000), while CI runners (e.g.
# GitHub Actions ubuntu-24.04) run as UID 1001, so the directory mounted at
# /zap/wrk must be writable by another UID. Stage it inside a private (0700)
# per-run parent: other local accounts can't reach it, and the sticky 1777
# mode lets the container add reports without being able to replace the
# config and hook files staged there. Reports are copied to OUTPUT_DIR after
# each scan. The bind mount resolves the host path as the Docker daemon, so
# the container needs no access to the private parent.
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zap-baseline.XXXXXX")"
chmod 0700 "$RUN_DIR"
ZAP_WRK="${RUN_DIR}/wrk"
mkdir "$ZAP_WRK"
chmod 1777 "$ZAP_WRK"
# Per-run readiness markers: each server writes its PID here only after it
# has bound its port, so a stale server from another run can't pass.
RUN_MARKERS="${RUN_DIR}/markers"
mkdir -m 0700 "$RUN_MARKERS"

PIDS=()
CREATED_DB=""

cleanup() {
  for pid in "${PIDS[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  if [[ -n "$CREATED_DB" ]]; then
    dropdb --if-exists --host 127.0.0.1 --username "${PGUSER:-postgres}" "$CREATED_DB" >/dev/null 2>&1 || true
  fi
  # Files ZAP wrote are owned by its UID; the sticky directory's owner may still remove them.
  rm -rf "$RUN_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Refuse to start if anything already answers on a port, so the scan can only
# reach the servers this run starts.
require_free_port() {
  local port="$1"
  local label="$2"
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${port}/"; then
    echo "Port ${port} for ${label} is already in use (another harness or server?). Stop it or set a different port." >&2
    exit 1
  fi
}

# Waits until `url` answers AND this run's own server is the one listening:
# the child process is still alive and its marker file (written only after a
# successful bind) names a live process started by this run.
wait_for_own_server() {
  local url="$1"
  local label="$2"
  local child_pid="$3"
  local marker_file="$4"
  local log_file="$5"
  local attempts=90
  local marker_pid=""
  for ((i=1; i<=attempts; i++)); do
    if ! kill -0 "$child_pid" 2>/dev/null; then
      echo "${label} exited before it was ready. Last log lines (${log_file}):" >&2
      tail -n 20 "$log_file" >&2 || true
      return 1
    fi
    if [[ -s "$marker_file" ]]; then
      marker_pid="$(tr -dc '0-9' <"$marker_file")"
      if [[ -n "$marker_pid" ]] && kill -0 "$marker_pid" 2>/dev/null &&
        curl -sS -o /dev/null --max-time 2 "$url" 2>/dev/null; then
        return 0
      fi
    fi
    sleep 1
  done
  echo "Timed out waiting for ${label} (this run's server) at ${url}" >&2
  return 1
}

run_zap_baseline() {
  local target_url="$1"
  local conf_file="$2"
  local prefix="$3"
  local hook_file="${4:-}"
  local docker_net_args=()
  local hook_args=()
  local zap_target="$target_url"

  if [[ "$MODE" == "local" ]]; then
    if [[ "$(uname -s)" == "Linux" ]]; then
      docker_net_args=(--network host)
    else
      zap_target="${target_url//127.0.0.1/host.docker.internal}"
      docker_net_args=(--add-host=host.docker.internal:host-gateway)
    fi
  fi

  # Staged read-only for the container user (0644 in a sticky directory).
  install -m 0644 "$conf_file" "${ZAP_WRK}/${prefix}.conf"
  if [[ -n "$hook_file" ]]; then
    local hook_basename
    hook_basename="$(basename "$hook_file")"
    install -m 0644 "$hook_file" "${ZAP_WRK}/${hook_basename}"
    hook_args=(--hook "/zap/wrk/${hook_basename}")
  fi

  echo "==> Running OWASP ZAP baseline (${prefix}) against ${zap_target}"
  local status=0
  docker run --rm \
    "${docker_net_args[@]}" \
    -v "${ZAP_WRK}:/zap/wrk:rw" \
    "$ZAP_IMAGE" \
    zap-baseline.py \
      -t "$zap_target" \
      -c "${prefix}.conf" \
      "${hook_args[@]}" \
      -r "${prefix}-report.html" \
      -J "${prefix}-report.json" \
      -w "${prefix}-report.md" \
      -m 2 \
      -I || status=$?

  # Copy whatever reports exist (also after a failure) so CI uploads them.
  safe_copy_file "${ZAP_WRK}/${prefix}.conf" "${OUTPUT_DIR}/${prefix}.conf"
  local report
  for report in "${ZAP_WRK}/${prefix}"-report.*; do
    [[ -e "$report" || -L "$report" ]] || continue
    safe_copy_file "$report" "${OUTPUT_DIR}/$(basename "$report")"
  done

  # ZAP baseline exit codes: 0 = pass, 2 = warn only (ignored with -I), 1/3 = fail/error.
  if [[ "$status" -ne 0 ]]; then
    echo "OWASP ZAP baseline FAILED for ${prefix} (exit ${status}). See ${OUTPUT_DIR}/${prefix}-report.md" >&2
    return "$status"
  fi

  local ext
  for ext in html json md; do
    if [[ ! -s "${OUTPUT_DIR}/${prefix}-report.${ext}" ]]; then
      echo "OWASP ZAP baseline did not write expected report ${OUTPUT_DIR}/${prefix}-report.${ext}" >&2
      return 1
    fi
  done
  echo "==> PASS: ${prefix} (reports saved under ${OUTPUT_DIR}/${prefix}-report.{html,json,md})"
}

if [[ "$MODE" == "local" ]]; then
  if [[ "$SKIP_BUILD" != "true" ]]; then
    echo "==> Building employee web surface (VITE_APP_SURFACE=employee, production mode with placeholder key)"
    # Base64 of "clerk.example.test$" (RFC 2606 .test placeholder, never a real key).
    (
      cd "${ROOT_DIR}/web"
      DEPLOYMENT_ENV=production \
      VITE_DEPLOYMENT_ENV=production \
      VITE_APP_SURFACE=employee \
      VITE_API_URL="https://employee-api.example.test/api/v1" \
      VITE_CLERK_PUBLISHABLE_KEY="pk_live_Y2xlcmsuZXhhbXBsZS50ZXN0JA==" \
      VITE_AUTH_ENABLED=true \
      npm run build
    )
  fi

  require_free_port "$WEB_PORT" "employee web server"
  require_free_port "$API_PORT" "employee API server"

  echo "==> Starting employee static server with _headers on 127.0.0.1:${WEB_PORT}"
  require_non_symlink_path "${OUTPUT_DIR}/web-server.log"
  python3 "${ROOT_DIR}/scripts/security/serve_employee_dist.py" \
    --dir "${ROOT_DIR}/web/dist" \
    --host "127.0.0.1" \
    --port "$WEB_PORT" \
    --ready-file "${RUN_MARKERS}/web.pid" >"${OUTPUT_DIR}/web-server.log" 2>&1 &
  web_pid="$!"
  PIDS+=("$web_pid")
  wait_for_own_server "http://127.0.0.1:${WEB_PORT}/" "employee web server" "$web_pid" \
    "${RUN_MARKERS}/web.pid" "${OUTPUT_DIR}/web-server.log"
  if [[ "$(tr -dc '0-9' <"${RUN_MARKERS}/web.pid")" != "$web_pid" ]]; then
    echo "Employee web server marker does not match the process this run started" >&2
    exit 1
  fi

  if [[ -z "${TEST_DATABASE_URL:-}" ]]; then
    CREATED_DB="cornerstone_payroll_zap_$$_test"
    createdb --host 127.0.0.1 --username "${PGUSER:-postgres}" "$CREATED_DB"
    export TEST_DATABASE_URL="postgres://${PGUSER:-postgres}:${PGPASSWORD:-}@127.0.0.1:5432/${CREATED_DB}"
    export DATABASE_URL="$TEST_DATABASE_URL"
    (
      cd "${ROOT_DIR}/api"
      RAILS_ENV=test bundle exec rails db:schema:load
    )
  fi

  # Run in production mode (with FORCE_SSL=false for loopback HTTP) so
  # consider_all_requests_local=false and Rack::Attack match production headers
  # and 404 handling. RLS_CONTEXT_GUARD_MODE=off avoids requiring a dedicated
  # payroll_app role for this HTTP-header scan (RLS is verified by RSpec under raise).
  echo "==> Starting employee API (APP_PROCESS_ROLE=employee_web, RAILS_ENV=production, FORCE_SSL=false) on 127.0.0.1:${API_PORT}"
  require_non_symlink_path "${OUTPUT_DIR}/api-server.log"
  (
    cd "${ROOT_DIR}/api"
    exec env APP_PROCESS_ROLE=employee_web \
    RAILS_ENV=production \
    DEPLOYMENT_ENV=production \
    FORCE_SSL=false \
    USE_SOLID_CACHE=false \
    USE_SOLID_QUEUE=false \
    ACTIVE_STORAGE_SERVICE=local \
    AUTH_ENABLED=true \
    REQUIRE_MFA=true \
    RLS_CONTEXT_GUARD_MODE=off \
    CLERK_ISSUER="https://clerk.example.test" \
    CLERK_AUTHORIZED_PARTIES="https://payroll.example.test" \
    DATABASE_URL="$TEST_DATABASE_URL" \
    SECRET_KEY_BASE="zap-local-scan-secret-key-base-0123456789abcdef0123456789abcdef" \
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="zap-local-scan-primary-key-0123456789" \
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="zap-local-scan-determ-key-0123456789" \
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="zap-local-scan-salt-0123456789abcdef" \
    bundle exec puma -b "tcp://127.0.0.1:${API_PORT}" -w 0 -t 2:2 --pidfile "${RUN_MARKERS}/api.pid"
  ) >"${OUTPUT_DIR}/api-server.log" 2>&1 &
  api_pid="$!"
  PIDS+=("$api_pid")
  # Puma writes its pidfile only after binding the listener; a bind failure exits.
  wait_for_own_server "http://127.0.0.1:${API_PORT}/up" "employee API server" "$api_pid" \
    "${RUN_MARKERS}/api.pid" "${OUTPUT_DIR}/api-server.log"

  # Smoke-verify employee_web process isolation before scanning.
  admin_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/api/v1/admin/companies")"
  if [[ "$admin_status" != "404" ]]; then
    echo "Expected /api/v1/admin/companies to return 404 under APP_PROCESS_ROLE=employee_web, got ${admin_status}" >&2
    exit 1
  fi

  WEB_URL="http://127.0.0.1:${WEB_PORT}/"
  API_URL="http://127.0.0.1:${API_PORT}/up"

  run_zap_baseline "$WEB_URL" "${ROOT_DIR}/scripts/security/zap_baseline_web_local.conf" "employee-web-local"
  run_zap_baseline "$API_URL" "${ROOT_DIR}/scripts/security/zap_baseline_api_local.conf" "employee-api-local" \
    "${ROOT_DIR}/scripts/security/zap_api_seed_hook.py"
else
  if [[ -z "$WEB_URL" || -z "$API_URL" ]]; then
    echo "Production mode requires --web-url and --api-url (both https://)." >&2
    exit 2
  fi
  if [[ "$WEB_URL" != https://* || "$API_URL" != https://* ]]; then
    echo "Production URLs must use https://" >&2
    exit 2
  fi

  api_target="${API_URL%/}/up"
  run_zap_baseline "$WEB_URL" "${ROOT_DIR}/scripts/security/zap_baseline_web_production.conf" "employee-web-production"
  run_zap_baseline "$api_target" "${ROOT_DIR}/scripts/security/zap_baseline_api_production.conf" "employee-api-production" \
    "${ROOT_DIR}/scripts/security/zap_api_seed_hook.py"
fi
