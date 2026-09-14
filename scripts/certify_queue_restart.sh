#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
API_DIR="$ROOT_DIR/api"
PORT="${QUEUE_PROBE_PORT:-44329}"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
DATABASE="cornerstone_queue_certification_${RUN_ID//-/_}"
TEMP_PARENT="${TMPDIR:-/tmp}"
while [[ "$TEMP_PARENT" != "/" && "$TEMP_PARENT" == */ ]]; do
  TEMP_PARENT="${TEMP_PARENT%/}"
done
TEMP_DIR="$(mktemp -d "$TEMP_PARENT/cornerstone-queue-certification.XXXXXX")"
WEB_LOG="$TEMP_DIR/web.log"
WORKER_LOG="$TEMP_DIR/worker.log"
WEB_PID=""
WORKER_PID=""
RBENV_ROOT="$(rbenv root 2>/dev/null || true)"

fail() {
  echo "Queue certification failed: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  for pid in "$WORKER_PID" "$WEB_PID"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
  dropdb --if-exists "$DATABASE" >/dev/null 2>&1 || true
  if [[ -d "$TEMP_DIR" ]] && ! /usr/bin/trash "$TEMP_DIR" 2>/dev/null; then
    if [[ "$TEMP_DIR" == "$TEMP_PARENT"/cornerstone-queue-certification.* ]]; then
      /bin/rm -rf -- "$TEMP_DIR"
    else
      echo "Refusing to remove unexpected queue-certification path: $TEMP_DIR" >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

[[ -n "$RBENV_ROOT" && -d "$RBENV_ROOT/shims" ]] || fail "rbenv is required"
[[ "$DATABASE" == cornerstone_queue_certification_* ]] || fail "unsafe database name"
[[ "$PORT" =~ ^[0-9]{4,5}$ ]] && ((PORT >= 1024 && PORT <= 65535)) || fail "QUEUE_PROBE_PORT must be between 1024 and 65535"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  fail "port $PORT is already in use"
fi

export PATH="$RBENV_ROOT/shims:$PATH"
export RAILS_ENV=test
export E2E_TEST_MODE=true
export SOLID_QUEUE_TEST_MODE=true
export TEST_DATABASE_URL="postgresql:///$DATABASE"
export DATABASE_URL="$TEST_DATABASE_URL"
export PROBE_ID="$(ruby -rsecurerandom -e 'puts SecureRandom.uuid')"

createdb "$DATABASE"
cd "$API_DIR"
bundle exec rails db:schema:load db:seed >/dev/null
bundle exec rails runner 'load Rails.root.join("db/queue_schema.rb") unless ActiveRecord::Base.connection.table_exists?("solid_queue_jobs")'

start_web() {
  bundle exec rails server -b 127.0.0.1 -p "$PORT" >"$WEB_LOG" 2>&1 &
  WEB_PID=$!
  for _attempt in {1..30}; do
    curl -fsS "http://127.0.0.1:$PORT/up" >/dev/null 2>&1 && return
    kill -0 "$WEB_PID" 2>/dev/null || fail "web process exited before becoming healthy"
    sleep 1
  done
  fail "web process did not become healthy"
}

start_web
first_web_pid="$WEB_PID"
bundle exec rails operations:queue_probe:enqueue >/dev/null

pending_effects="$(bundle exec rails runner 'puts OperationalQueueProbe.find_by!(probe_id: ENV.fetch("PROBE_ID")).effect_count')"
[[ "$pending_effects" == "0" ]] || fail "probe ran before the worker started"

kill "$WEB_PID"
wait "$WEB_PID" 2>/dev/null || true
WEB_PID=""
start_web
[[ "$WEB_PID" != "$first_web_pid" ]] || fail "web process did not restart"

bundle exec bin/jobs >"$WORKER_LOG" 2>&1 &
WORKER_PID=$!

for _attempt in {1..30}; do
  first_status="$(bundle exec rails runner 'probe = OperationalQueueProbe.find_by!(probe_id: ENV.fetch("PROBE_ID")); puts [probe.attempt_count, probe.effect_count, probe.completed_at&.iso8601].join("|")')"
  [[ "$first_status" == 1\|1\|* ]] && break
  kill -0 "$WORKER_PID" 2>/dev/null || fail "worker exited before completing the probe"
  sleep 1
done
[[ "$first_status" == 1\|1\|* ]] || fail "queued probe did not complete exactly once"
first_completed_at="${first_status#*|*|}"

bundle exec rails operations:queue_probe:replay >/dev/null
for _attempt in {1..30}; do
  replay_status="$(bundle exec rails runner 'probe = OperationalQueueProbe.find_by!(probe_id: ENV.fetch("PROBE_ID")); puts [probe.attempt_count, probe.effect_count, probe.completed_at&.iso8601].join("|")')"
  [[ "$replay_status" == 2\|1\|* ]] && break
  kill -0 "$WORKER_PID" 2>/dev/null || fail "worker exited before completing the replay"
  sleep 1
done
[[ "$replay_status" == "2|1|$first_completed_at" ]] || fail "replay changed the single durable effect"

bundle exec rails operations:queue_probe:cleanup >/dev/null
remaining="$(bundle exec rails runner 'puts OperationalQueueProbe.where(probe_id: ENV.fetch("PROBE_ID")).count')"
[[ "$remaining" == "0" ]] || fail "probe cleanup did not remove the exact record"

echo "LOCAL QUEUE RESTART CERTIFICATION PASSED"
echo "first_web_pid=$first_web_pid"
echo "restarted_web_pid=$WEB_PID"
echo "worker_pid=$WORKER_PID"
echo "attempt_count=2"
echo "effect_count=1"
