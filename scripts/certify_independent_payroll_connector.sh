#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PAYROLL_REPO_PATH="${PAYROLL_REPO_PATH:-$ROOT_DIR}"
PRODUCER_PORT="${PRODUCER_PORT:-44341}"
RUN_ID="$(date +%Y%m%d%H%M%S)_$$"
CERT_DATABASE="cornerstone_neutral_certification_$RUN_ID"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cornerstone-neutral-certification.XXXXXX")"
PRODUCER_PID=""
RESULT_PATH="${NEUTRAL_CERTIFICATION_RESULT:-$TEMP_DIR/result.json}"
LIFECYCLE_TOOL="${LIFECYCLE_TOOL:-/Users/leonshimizu/.local/bin/dev-lifecycle}"
source "$ROOT_DIR/scripts/local_certification/runtime.sh"

cleanup() {
  local status=$? cleanup_failed=0
  trap - EXIT INT TERM
  if [[ -n "$PRODUCER_PID" ]]; then
    if kill -0 "$PRODUCER_PID" 2>/dev/null; then
      kill "$PRODUCER_PID" || cleanup_failed=1
    fi
    wait "$PRODUCER_PID" 2>/dev/null || true
    if kill -0 "$PRODUCER_PID" 2>/dev/null; then
      echo "Owned producer remains: PID $PRODUCER_PID" >&2
      cleanup_failed=1
    elif [[ -n "${LIFECYCLE_SESSION_ID:-}" && -x "$LIFECYCLE_TOOL" ]]; then
      "$LIFECYCLE_TOOL" release process "$PRODUCER_PID" --session "$LIFECYCLE_SESSION_ID" >/dev/null || cleanup_failed=1
    fi
  fi
  if [[ "$CERT_DATABASE" == cornerstone_neutral_certification_* ]]; then
    dropdb --if-exists "$CERT_DATABASE" >/dev/null 2>&1 || {
      echo "Owned database cleanup failed: $CERT_DATABASE" >&2; cleanup_failed=1;
    }
  fi
  if [[ "$cleanup_failed" == 0 && "$TEMP_DIR" == */cornerstone-neutral-certification.* ]]; then
    rm -rf -- "$TEMP_DIR" || cleanup_failed=1
  fi
  if [[ "$cleanup_failed" != 0 ]]; then
    echo "Cleanup incomplete; private diagnostics retained at $TEMP_DIR" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

[[ "$PRODUCER_PORT" =~ ^[0-9]{4,5}$ && "$PRODUCER_PORT" -ge 1024 && "$PRODUCER_PORT" -le 65535 ]] || {
  echo "Use an unprivileged producer port" >&2; exit 1;
}
if lsof -nP -iTCP:"$PRODUCER_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Independent producer port is already occupied" >&2; exit 1
fi
git -C "$PAYROLL_REPO_PATH" diff --quiet HEAD || { echo "Certify a clean tracked application checkout" >&2; exit 1; }
[[ ! -e "$RESULT_PATH" ]] || { echo "Refusing to overwrite an existing certificate" >&2; exit 1; }
certification_use_ruby "$PAYROLL_REPO_PATH/api" "${PAYROLL_RUBY_BIN_DIR:-}"
python3 -m unittest discover -s "$ROOT_DIR/scripts/connector_certification" -p 'test_*.py'
python3 - "$TEMP_DIR/config.json" <<'PY'
import json, os, secrets, sys, uuid
path = sys.argv[1]
with open(path, 'x') as output:
    json.dump({"shared_secret": secrets.token_urlsafe(32), "source_instance_id": str(uuid.uuid4()),
               "employee_uuid": str(uuid.uuid4()), "employee_id": 2, "clock": "2026-10-01T00:00:00Z"}, output)
os.chmod(path, 0o600)
PY
CONNECTOR_CERTIFICATION=disposable_test_only python3 "$ROOT_DIR/scripts/connector_certification/producer.py" \
  --config "$TEMP_DIR/config.json" --port "$PRODUCER_PORT" >"$TEMP_DIR/producer.log" 2>&1 &
PRODUCER_PID=$!
if [[ -n "${LIFECYCLE_SESSION_ID:-}" && -x "$LIFECYCLE_TOOL" ]]; then
  "$LIFECYCLE_TOOL" claim process "$PRODUCER_PID" --session "$LIFECYCLE_SESSION_ID" --owner root \
    --reason "Independent disposable payroll connector certification" --url "http://localhost:$PRODUCER_PORT"
fi
createdb "$CERT_DATABASE"
(
  cd "$PAYROLL_REPO_PATH/api"
  export RAILS_ENV=test E2E_TEST_MODE=true AUTH_ENABLED=false
  export CONNECTOR_CERTIFICATION=disposable_test_only TEST_DATABASE_URL="postgresql:///$CERT_DATABASE"
  export NEUTRAL_PRODUCER_CONFIG="$TEMP_DIR/config.json" NEUTRAL_PRODUCER_URL="http://localhost:$PRODUCER_PORT"
  export NEUTRAL_CERTIFICATION_RESULT="$RESULT_PATH"
  bundle exec rails db:schema:load db:seed >"$TEMP_DIR/database.log" 2>&1 || { cat "$TEMP_DIR/database.log" >&2; exit 1; }
  bundle exec rails runner "$ROOT_DIR/scripts/connector_certification/verify_cornerstone.rb"
)
[[ -f "$RESULT_PATH" ]] || { echo "Independent result was not created" >&2; exit 1; }
if [[ "$RESULT_PATH" == "$TEMP_DIR"/* ]]; then
  cat "$RESULT_PATH"
else
  echo "Independent certification result saved to $RESULT_PATH"
fi
