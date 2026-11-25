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

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

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
}
trap cleanup EXIT

wait_for_http() {
  local url="$1"
  local label="$2"
  local attempts=45
  for ((i=1; i<=attempts; i++)); do
    if curl -sS -o /dev/null --max-time 2 "$url"; then
      return 0
    fi
    sleep 1
  done
  echo "Timed out waiting for ${label} at ${url}" >&2
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

  cp "$conf_file" "${OUTPUT_DIR}/${prefix}.conf"
  if [[ -n "$hook_file" ]]; then
    local hook_basename
    hook_basename="$(basename "$hook_file")"
    cp "$hook_file" "${OUTPUT_DIR}/${hook_basename}"
    hook_args=(--hook "/zap/wrk/${hook_basename}")
  fi

  echo "==> Running OWASP ZAP baseline (${prefix}) against ${zap_target}"
  local status=0
  docker run --rm \
    "${docker_net_args[@]}" \
    -v "${OUTPUT_DIR}:/zap/wrk:rw" \
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

  # ZAP baseline exit codes: 0 = pass, 2 = warn only (ignored with -I), 1/3 = fail/error.
  if [[ "$status" -ne 0 ]]; then
    echo "OWASP ZAP baseline FAILED for ${prefix} (exit ${status}). See ${OUTPUT_DIR}/${prefix}-report.md" >&2
    return "$status"
  fi
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

  echo "==> Starting employee static server with _headers on 127.0.0.1:${WEB_PORT}"
  python3 "${ROOT_DIR}/scripts/security/serve_employee_dist.py" \
    --dir "${ROOT_DIR}/web/dist" \
    --host "127.0.0.1" \
    --port "$WEB_PORT" >"${OUTPUT_DIR}/web-server.log" 2>&1 &
  PIDS+=("$!")
  wait_for_http "http://127.0.0.1:${WEB_PORT}/" "employee web server"

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
  (
    cd "${ROOT_DIR}/api"
    APP_PROCESS_ROLE=employee_web \
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
    DATABASE_URL="${DATABASE_URL:-$TEST_DATABASE_URL}" \
    SECRET_KEY_BASE="zap-local-scan-secret-key-base-0123456789abcdef0123456789abcdef" \
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="zap-local-scan-primary-key-0123456789" \
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="zap-local-scan-determ-key-0123456789" \
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="zap-local-scan-salt-0123456789abcdef" \
    bundle exec puma -b "tcp://127.0.0.1:${API_PORT}" -w 0 -t 2:2
  ) >"${OUTPUT_DIR}/api-server.log" 2>&1 &
  PIDS+=("$!")
  wait_for_http "http://127.0.0.1:${API_PORT}/up" "employee API server"

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
