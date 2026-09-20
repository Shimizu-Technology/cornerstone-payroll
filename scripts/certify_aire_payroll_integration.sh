#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "Certification driver PID: $$"
AIRE_REPO_PATH="${AIRE_REPO_PATH:-}"
AIRE_PORT="${AIRE_PORT:-44327}"
CORNERSTONE_PORT="${CORNERSTONE_PORT:-44328}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
BROWSER_REVIEW_ONLY="${BROWSER_REVIEW_ONLY:-false}"
RUN_ID="$(date +%Y%m%d%H%M%S)-$$"
AIRE_DATABASE="aire_cornerstone_certification_${RUN_ID//-/_}"
CORNERSTONE_DATABASE="cornerstone_aire_certification_${RUN_ID//-/_}"
TEMP_PARENT="${TMPDIR:-/tmp}"
while [[ "$TEMP_PARENT" != "/" && "$TEMP_PARENT" == */ ]]; do
  TEMP_PARENT="${TEMP_PARENT%/}"
done
TEMP_DIR="$(mktemp -d "$TEMP_PARENT/cornerstone-aire-certification.XXXXXX")"
AIRE_FIXTURE="$TEMP_DIR/aire.json"
CORNERSTONE_FIXTURE="$TEMP_DIR/cornerstone.json"
AIRE_LOG="$TEMP_DIR/aire.log"
CORNERSTONE_LOG="$TEMP_DIR/cornerstone.log"
AIRE_PID=""
CORNERSTONE_PID=""
RBENV_ROOT="$(rbenv root 2>/dev/null || true)"

fail() {
  echo "Certification failed: $*" >&2
  exit 1
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM

  if [[ -n "$CORNERSTONE_PID" ]] && kill -0 "$CORNERSTONE_PID" 2>/dev/null; then
    kill "$CORNERSTONE_PID" 2>/dev/null || true
    wait "$CORNERSTONE_PID" 2>/dev/null || true
  fi
  if [[ -n "$AIRE_PID" ]] && kill -0 "$AIRE_PID" 2>/dev/null; then
    kill "$AIRE_PID" 2>/dev/null || true
    wait "$AIRE_PID" 2>/dev/null || true
  fi

  dropdb --if-exists "$CORNERSTONE_DATABASE" >/dev/null 2>&1 || true
  dropdb --if-exists "$AIRE_DATABASE" >/dev/null 2>&1 || true
  if [[ -d "$TEMP_DIR" ]] && ! /usr/bin/trash "$TEMP_DIR" 2>/dev/null; then
    if [[ "$TEMP_DIR" == "$TEMP_PARENT"/cornerstone-aire-certification.* ]]; then
      /bin/rm -rf -- "$TEMP_DIR"
    else
      echo "Refusing to remove an unexpected certification temporary path: $TEMP_DIR" >&2
    fi
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

[[ -n "$AIRE_REPO_PATH" ]] || fail "set AIRE_REPO_PATH to the local aire-services repository"
[[ -d "$AIRE_REPO_PATH/backend" ]] || fail "AIRE_REPO_PATH must contain backend/"
[[ -f "$AIRE_REPO_PATH/backend/app/models/payroll_integration_grant.rb" ]] || fail "the selected AIRE repository does not support delegated payroll"
[[ -n "$RBENV_ROOT" && -d "$RBENV_ROOT/shims" ]] || fail "rbenv is required to select each repository's pinned Ruby"
[[ -f "$ROOT_DIR/api/.ruby-version" && -f "$AIRE_REPO_PATH/backend/.ruby-version" ]] || fail "both Rails applications must pin Ruby in .ruby-version"
[[ "$AIRE_DATABASE" == aire_cornerstone_certification_* ]] || fail "unsafe AIRE database name"
[[ "$CORNERSTONE_DATABASE" == cornerstone_aire_certification_* ]] || fail "unsafe Cornerstone database name"

for port in "$AIRE_PORT" "$CORNERSTONE_PORT"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail "port $port is already in use"
  fi
done

SHARED_SECRET="local-certification-$(ruby -rsecurerandom -e 'print SecureRandom.hex(24)')"
AIRE_DATABASE_URL="postgresql:///$AIRE_DATABASE"
CORNERSTONE_DATABASE_URL="postgresql:///$CORNERSTONE_DATABASE"
AIRE_BASE_URL="http://localhost:$AIRE_PORT"
CORNERSTONE_BASE_URL="http://localhost:$CORNERSTONE_PORT"

echo "Preparing isolated local databases..."
createdb "$AIRE_DATABASE"
createdb "$CORNERSTONE_DATABASE"

(
  cd "$AIRE_REPO_PATH/backend"
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_VERSION="$(<"$AIRE_REPO_PATH/backend/.ruby-version")"
  RAILS_ENV=test TEST_DATABASE_URL="$AIRE_DATABASE_URL" bundle exec rails db:schema:load
  RAILS_ENV=test E2E_TEST_MODE=true TEST_DATABASE_URL="$AIRE_DATABASE_URL" \
    PAYROLL_SHARED_SECRET="$SHARED_SECRET" CERTIFICATION_FIXTURE_PATH="$AIRE_FIXTURE" \
    bundle exec rails runner "$ROOT_DIR/scripts/local_certification/seed_aire.rb"
)

(
  cd "$ROOT_DIR/api"
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_VERSION="$(<"$ROOT_DIR/api/.ruby-version")"
  RAILS_ENV=test TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" bundle exec rails db:schema:load db:seed >/dev/null
  RAILS_ENV=test E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    AIRE_CERTIFICATION_FIXTURE_PATH="$AIRE_FIXTURE" CERTIFICATION_FIXTURE_PATH="$CORNERSTONE_FIXTURE" \
    AIRE_BASE_URL="$AIRE_BASE_URL" bundle exec rails runner "$ROOT_DIR/scripts/local_certification/seed_cornerstone.rb"
)

json_value() {
  ruby -rjson -e 'print JSON.parse(File.read(ARGV.fetch(0))).fetch(ARGV.fetch(1))' "$1" "$2"
}

COMPANY_ID="$(json_value "$CORNERSTONE_FIXTURE" company_id)"
PAY_PERIOD_ID="$(json_value "$CORNERSTONE_FIXTURE" pay_period_id)"
NEXT_PAY_PERIOD_ID="$(json_value "$CORNERSTONE_FIXTURE" next_pay_period_id)"
SOURCE_ID="$(json_value "$CORNERSTONE_FIXTURE" source_id)"
EMPLOYEE_ID="$(json_value "$CORNERSTONE_FIXTURE" employee_id)"
WAGE_RATE_ID="$(json_value "$CORNERSTONE_FIXTURE" employee_wage_rate_id)"
ADMIN_EMAIL="$(json_value "$CORNERSTONE_FIXTURE" admin_email)"
START_DATE="$(json_value "$CORNERSTONE_FIXTURE" start_date)"
END_DATE="$(json_value "$CORNERSTONE_FIXTURE" end_date)"
MANUAL_APPROVE_ID="$(json_value "$AIRE_FIXTURE" approved_manual_entry_id)"
MANUAL_HOLD_ID="$(json_value "$AIRE_FIXTURE" held_manual_entry_id)"
AIRE_EMPLOYEE_ID="$(json_value "$AIRE_FIXTURE" employee_id)"
AIRE_CATEGORY_ID="$(json_value "$AIRE_FIXTURE" category_id)"
AIRE_CATEGORY_KEY="$(json_value "$AIRE_FIXTURE" category_key)"
AIRE_CATEGORY_NAME="$(json_value "$AIRE_FIXTURE" category_name)"
CUTOFF_AT="$(json_value "$AIRE_FIXTURE" cutoff_at)"

echo "Starting isolated AIRE and Cornerstone APIs..."
(
  cd "$AIRE_REPO_PATH/backend"
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_VERSION="$(<"$AIRE_REPO_PATH/backend/.ruby-version")"
  exec env RAILS_ENV=test E2E_TEST_MODE=true TEST_DATABASE_URL="$AIRE_DATABASE_URL" \
    PAYROLL_SHARED_SECRET="$SHARED_SECRET" \
    CORNERSTONE_PAYROLL_EVENTS_URL="$CORNERSTONE_BASE_URL/api/v1/integrations/aire/events" \
    bundle exec rails server --binding 127.0.0.1 --port "$AIRE_PORT"
) >"$AIRE_LOG" 2>&1 &
AIRE_PID=$!

(
  cd "$ROOT_DIR/api"
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_VERSION="$(<"$ROOT_DIR/api/.ruby-version")"
  exec env RAILS_ENV=test AUTH_ENABLED=false E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    CORS_ORIGINS="${CORNERSTONE_WEB_ORIGIN:-http://127.0.0.1:44329}" \
    bundle exec rails server --binding 127.0.0.1 --port "$CORNERSTONE_PORT"
) >"$CORNERSTONE_LOG" 2>&1 &
CORNERSTONE_PID=$!
echo "Owned server PIDs: AIRE=$AIRE_PID Cornerstone=$CORNERSTONE_PID"

wait_for_health() {
  local url=$1
  local name=$2
  local log=$3
  for _attempt in $(seq 1 60); do
    if curl --silent --fail --connect-timeout 3 --max-time 5 "$url/up" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  tail -80 "$log" >&2 || true
  fail "$name did not become healthy"
}
wait_for_health "$AIRE_BASE_URL" AIRE "$AIRE_LOG"
wait_for_health "$CORNERSTONE_BASE_URL" Cornerstone "$CORNERSTONE_LOG"

api_call() {
  local expected=$1
  local label=$2
  local method=$3
  local url=$4
  local output=$5
  local body=${6:-}
  local status
  local args=(--silent --show-error --connect-timeout 5 --max-time 30 \
    --output "$output" --write-out "%{http_code}" --request "$method" \
    --header "Accept: application/json" --header "Content-Type: application/json" \
    --header "X-E2E-User-Email: $ADMIN_EMAIL" --header "X-Company-Id: $COMPANY_ID")
  [[ -z "$body" ]] || args+=(--data-binary "@$body")
  status="$(curl "${args[@]}" "$url")"
  [[ "$status" == "$expected" ]] || {
    echo "$label returned HTTP $status" >&2
    ruby -rjson -e 'data=JSON.parse(File.read(ARGV[0])); puts({error: data["error"]}.compact.to_json)' "$output" 2>/dev/null || true
    fail "$label"
  }
  echo "PASS: $label"
}

PUBLISH_RESPONSE="$TEMP_DIR/publish.json"
api_call 201 "publish the post-pay calendar from Cornerstone to AIRE" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_calendar/publish" "$PUBLISH_RESPONSE"
NEXT_PUBLISH_RESPONSE="$TEMP_DIR/next-publish.json"
api_call 201 "publish the next available AIRE payroll period" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$NEXT_PAY_PERIOD_ID/aire_payroll_calendar/publish" "$NEXT_PUBLISH_RESPONSE"
(
  cd "$ROOT_DIR/api"
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_VERSION="$(<"$ROOT_DIR/api/.ruby-version")"
  RAILS_ENV=test AUTH_ENABLED=false E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    bundle exec rails runner '
      publications = AirePayrollCalendarPublication.order(:id).to_a
      abort "missing calendar publications" unless publications.size == 2
      publications.each do |publication|
        unless publication.delivered?
          result = AirePayrollCalendar::Delivery.new(publication_id: publication.id).call
          abort "calendar delivery failed: #{result[:error]}" unless result.fetch(:status) == "delivered"
        end
      end
      puts "PASS: both published calendar periods reached AIRE"
    '
)

OVERVIEW_BEFORE="$TEMP_DIR/overview-before.json"
api_call 200 "load live AIRE hours in Cornerstone" GET \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit" "$OVERVIEW_BEFORE"
ruby -rjson -e '
  data=JSON.parse(File.read(ARGV[0])).fetch("aire_payroll_cockpit")
  ready=data.fetch("readiness")
  abort "unexpected pre-cutoff totals" unless ready.fetch("total_entries") == 3 && ready.fetch("eligible_entries") == 1 && ready.fetch("pending_approvals") == 2
  abort "delegated commands are unavailable" unless data.dig("command_access", "can_command")
' "$OVERVIEW_BEFORE"
echo "PASS: ordinary time is eligible and both manual entries require review"

APPROVAL_BODY="$TEMP_DIR/approval.json"
APPROVAL_COMMAND="$(ruby -rsecurerandom -e 'print SecureRandom.uuid')"
ruby -rjson -e 'File.write(ARGV[0], JSON.generate(command_id: ARGV[1], expected_version: 0, decision: "approve", reason: "Reviewed synthetic manual time before cutoff"))' \
  "$APPROVAL_BODY" "$APPROVAL_COMMAND"
APPROVAL_RESPONSE="$TEMP_DIR/approval-response.json"
api_call 200 "approve manual time through Cornerstone" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/time_entries/$MANUAL_APPROVE_ID/approval" \
  "$APPROVAL_RESPONSE" "$APPROVAL_BODY"
APPROVED_ENTRY_VERSION="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("time_entry", "version")' "$APPROVAL_RESPONSE")"
APPROVED_OVERTIME_STATUS="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("time_entry", "state", "overtime_status")' "$APPROVAL_RESPONSE")"
[[ "$APPROVED_ENTRY_VERSION" =~ ^[0-9]+$ ]] || fail "manual-time approval did not return an entry version"
[[ "$APPROVED_OVERTIME_STATUS" == "pending" ]] || fail "daily overtime was not routed for explicit approval"
REPLAY_RESPONSE="$TEMP_DIR/approval-replay.json"
api_call 200 "replay the same delegated approval idempotently" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/time_entries/$MANUAL_APPROVE_ID/approval" \
  "$REPLAY_RESPONSE" "$APPROVAL_BODY"
ruby -rjson -e 'abort "approval was executed twice" unless JSON.parse(File.read(ARGV[0])).dig("command", "replayed") == true' "$REPLAY_RESPONSE"

OVERTIME_BODY="$TEMP_DIR/overtime-approval.json"
ruby -rjson -rsecurerandom -e 'File.write(ARGV[0], JSON.generate(command_id: SecureRandom.uuid, expected_version: ARGV[1].to_i, decision: "approve", reason: "Verified synthetic daily overtime before cutoff"))' \
  "$OVERTIME_BODY" "$APPROVED_ENTRY_VERSION"
OVERTIME_RESPONSE="$TEMP_DIR/overtime-approval-response.json"
api_call 200 "approve daily overtime through Cornerstone" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/time_entries/$MANUAL_APPROVE_ID/overtime_approval" \
  "$OVERTIME_RESPONSE" "$OVERTIME_BODY"
ruby -rjson -e '
  entry=JSON.parse(File.read(ARGV[0])).fetch("time_entry")
  abort "daily overtime approval was not recorded" unless entry.dig("state", "overtime_status") == "approved"
  abort "approved manual time is not payable" unless entry.dig("state", "payable_now") == true
' "$OVERTIME_RESPONSE"
echo "PASS: manual time and its daily overtime were explicitly approved through Cornerstone"

STALE_BODY="$TEMP_DIR/stale.json"
ruby -rjson -rsecurerandom -e 'File.write(ARGV[0], JSON.generate(command_id: SecureRandom.uuid, expected_version: 99, decision: "approve", reason: "Deliberate stale-version certification"))' "$STALE_BODY"
STALE_RESPONSE="$TEMP_DIR/stale-response.json"
api_call 409 "reject a stale manual-time decision" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/time_entries/$MANUAL_HOLD_ID/approval" \
  "$STALE_RESPONSE" "$STALE_BODY"

if [[ "$BROWSER_REVIEW_ONLY" == "true" ]]; then
  echo "Synthetic pre-pay browser fixture is ready; no payroll or payment has been recorded."
  echo "Cornerstone API: $CORNERSTONE_BASE_URL"
  echo "AIRE API: $AIRE_BASE_URL"
  echo "Synthetic pay period ID: $PAY_PERIOD_ID"
  echo "Synthetic company ID: $COMPANY_ID"
  echo "Synthetic admin email: $ADMIN_EMAIL"
  echo "Press Ctrl-C when browser review is complete; fixture databases and servers will be cleaned."
  wait "$AIRE_PID" "$CORNERSTONE_PID"
  exit 0
fi

echo "Waiting for the synthetic cutoff at $CUTOFF_AT..."
until ruby -rtime -e 'exit(Time.now >= Time.iso8601(ARGV[0]) ? 0 : 1)' "$CUTOFF_AT"; do
  sleep 2
done

FINALIZE_BODY="$TEMP_DIR/finalize.json"
ruby -rjson -rsecurerandom -e 'File.write(ARGV[0], JSON.generate(command_id: SecureRandom.uuid, expected_version: 0, reason: "Reviewed readiness and locked the synthetic cutoff"))' "$FINALIZE_BODY"
FINALIZE_RESPONSE="$TEMP_DIR/finalize-response.json"
api_call 202 "lock the due AIRE period from Cornerstone" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/finalize" \
  "$FINALIZE_RESPONSE" "$FINALIZE_BODY"

echo "Delivering and verifying AIRE's immutable finalized event over local HTTP..."
(
  cd "$AIRE_REPO_PATH/backend"
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_VERSION="$(<"$AIRE_REPO_PATH/backend/.ruby-version")"
  RAILS_ENV=test E2E_TEST_MODE=true TEST_DATABASE_URL="$AIRE_DATABASE_URL" \
    PAYROLL_SHARED_SECRET="$SHARED_SECRET" \
    CORNERSTONE_PAYROLL_EVENTS_URL="$CORNERSTONE_BASE_URL/api/v1/integrations/aire/events" \
    bundle exec rails runner '
      event = PayrollOutboxEvent.order(:id).last or abort "missing finalized outbox event"
      result = Payroll::OutboxDispatcher.new(event_id: event.id).call
      abort "outbox delivery failed" unless result.fetch(:status) == "delivered"
      puts "PASS: AIRE finalized event reached Cornerstone"
    '
)
(
  cd "$ROOT_DIR/api"
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_VERSION="$(<"$ROOT_DIR/api/.ruby-version")"
  RAILS_ENV=test AUTH_ENABLED=false E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    bundle exec rails runner '
      event = AirePayrollEvent.order(:id).last or abort "missing received AIRE event"
      result = AirePayrollEvents::Verifier.new(event_id: event.id).call
      abort "batch verification failed" unless result.fetch(:status) == "verified"
      puts "PASS: Cornerstone fetched and verified the immutable AIRE batch"
    '
)

PREVIEW_BODY="$TEMP_DIR/preview-body.json"
ruby -rjson -e 'File.write(ARGV[0], JSON.generate(source_id: ARGV[1].to_i, start_date: ARGV[2], end_date: ARGV[3]))' \
  "$PREVIEW_BODY" "$SOURCE_ID" "$START_DATE" "$END_DATE"
PREVIEW_RESPONSE="$TEMP_DIR/preview-response.json"
api_call 200 "preview the verified AIRE batch for payroll" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/preview_time_tracking_import" \
  "$PREVIEW_RESPONSE" "$PREVIEW_BODY"
IMPORT_ID="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("import", "id")' "$PREVIEW_RESPONSE")"

APPLY_BODY="$TEMP_DIR/apply-body.json"
ruby -rjson -e '
  File.write(ARGV[0], JSON.generate(
    import_id: ARGV[1].to_i,
    mappings: [{
      source_user_id: ARGV[2], employee_id: ARGV[3].to_i, include: true,
      wage_rate_mappings: [{
        source_category_id: ARGV[4], source_category_key: ARGV[5], source_category_name: ARGV[6],
        source_effective_rate_cents: 2500, employee_wage_rate_id: ARGV[7].to_i
      }]
    }]
  ))
' "$APPLY_BODY" "$IMPORT_ID" "$AIRE_EMPLOYEE_ID" "$EMPLOYEE_ID" "$AIRE_CATEGORY_ID" "$AIRE_CATEGORY_KEY" "$AIRE_CATEGORY_NAME" "$WAGE_RATE_ID"
APPLY_RESPONSE="$TEMP_DIR/apply-response.json"
api_call 200 "apply the finalized AIRE batch to Cornerstone payroll" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/apply_time_tracking_import" \
  "$APPLY_RESPONSE" "$APPLY_BODY"

RUN_RESPONSE="$TEMP_DIR/run-response.json"
api_call 200 "calculate payroll from the imported hours" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/run_payroll" "$RUN_RESPONSE"
ruby -rjson -e '
  data=JSON.parse(File.read(ARGV[0]))
  abort "payroll calculation errors" unless data.dig("results", "errors") == []
  item=data.dig("pay_period", "payroll_items")&.first or abort "missing calculated payroll item"
  abort "eligible regular hours were not 8.0" unless item.fetch("hours_worked").to_f == 8.0
  abort "eligible overtime hours were not 6.0" unless item.fetch("overtime_hours").to_f == 6.0
  abort "gross pay did not preserve the overtime premium" unless item.fetch("gross_pay").to_f == 425.0
' "$RUN_RESPONSE"

APPROVE_RESPONSE="$TEMP_DIR/payroll-approve.json"
api_call 200 "approve the calculated Cornerstone payroll" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/approve" "$APPROVE_RESPONSE"
COMMIT_RESPONSE="$TEMP_DIR/payroll-commit.json"
api_call 200 "commit the synthetic Cornerstone payroll" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/commit" "$COMMIT_RESPONSE"
PAYROLL_ITEM_ID="$(ruby -rjson -e 'print JSON.parse(File.read(ARGV[0])).dig("pay_period", "payroll_items", 0, "id")' "$RUN_RESPONSE")"

PRINT_RESPONSE="$TEMP_DIR/print.json"
api_call 200 "record the synthetic paper check as prepared" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/payroll_items/$PAYROLL_ITEM_ID/check/mark_printed" "$PRINT_RESPONSE"
DELIVERY_BODY="$TEMP_DIR/delivery.json"
TZ=Pacific/Guam ruby -rjson -rdate -e 'File.write(ARGV[0], JSON.generate(delivered_on: Date.today.iso8601, delivery_method: "hand_delivery", attestation: true, evidence_reference: "LOCAL-CERTIFICATION-ONLY", note: "Synthetic local delivery proof"))' "$DELIVERY_BODY"
DELIVERY_RESPONSE="$TEMP_DIR/delivery-response.json"
api_call 200 "record synthetic check delivery as the payment event" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/payroll_items/$PAYROLL_ITEM_ID/check/mark_delivered" \
  "$DELIVERY_RESPONSE" "$DELIVERY_BODY"

(
  cd "$ROOT_DIR/api"
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_VERSION="$(<"$ROOT_DIR/api/.ruby-version")"
  RAILS_ENV=test AUTH_ENABLED=false E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    bundle exec rails runner '
      AirePayrollAcknowledgement.undelivered.order(:id).find_each { |ack| AirePayrollStatusSyncJob.perform_now(ack.id) }
      AirePayrollEntryAcknowledgement.undelivered.order(:id).find_each { |ack| AirePayrollEntryStatusSyncJob.perform_now(ack.id) }
      abort "batch acknowledgements remain" if AirePayrollAcknowledgement.undelivered.exists?
      abort "entry acknowledgements remain" if AirePayrollEntryAcknowledgement.undelivered.exists?
      puts "PASS: imported, committed, and paid states reached AIRE"
    '
)

FINAL_OVERVIEW="$TEMP_DIR/final-overview.json"
api_call 200 "reload final AIRE history through Cornerstone" GET \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit" "$FINAL_OVERVIEW"
ruby -rjson -e '
  data=JSON.parse(File.read(ARGV[0])).fetch("aire_payroll_cockpit")
  abort "AIRE batch is not finalized" unless data.dig("payroll_period", "status") == "finalized"
  abort "held hours were lost" unless data.dig("readiness", "held_hours").to_f == 4.0
  statuses=data.fetch("processing_history").map { |event| event.fetch("status") }
  abort "AIRE is missing committed history" unless statuses.include?("committed")
' "$FINAL_OVERVIEW"
FINAL_ENTRIES="$TEMP_DIR/final-entries.json"
api_call 200 "reload entry-level payment state through Cornerstone" GET \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/time_entries" "$FINAL_ENTRIES"
ruby -rjson -e '
  entries=JSON.parse(File.read(ARGV[0])).fetch("time_entries")
  paid=entries.count { |entry| entry.dig("lifecycle", "status") == "payment_issued" }
  held=entries.count { |entry| entry.dig("lifecycle", "status") == "awaiting_approval" }
  abort "expected two paid source entries" unless paid == 2
  abort "expected one held source entry" unless held == 1
' "$FINAL_ENTRIES"
echo "PASS: four held hours remain visible and unpaid for the next available period"

NEXT_SETTLEMENTS="$TEMP_DIR/next-settlements.json"
api_call 200 "load held-time history in the next available pay period" GET \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$NEXT_PAY_PERIOD_ID/aire_payroll_cockpit/settlement_cases" "$NEXT_SETTLEMENTS"
ruby -rjson -e '
  cases=JSON.parse(File.read(ARGV[0])).fetch("settlement_cases")
  held=cases.find { |settlement_case| settlement_case.fetch("source_time_entry_id") == ARGV[1] }
  abort "held entry is missing from the next pay period" unless held
  abort "held entry was not scheduled for the next regular payroll" unless held.fetch("status") == "scheduled" && held.dig("routing", "destination_kind") == "regular"
  abort "held entry hours changed during carry-forward" unless held.dig("time", "held_total_hours").to_f == 4.0
  abort "held entry no longer awaits approval" unless held.dig("time", "approval_status") == "pending"
  abort "held entry was incorrectly marked as processed" if held["processing"] || held["included_payroll_batch_id"]
' "$NEXT_SETTLEMENTS" "$MANUAL_HOLD_ID"
echo "PASS: the next pay period shows all four held hours as scheduled and unpaid"

echo "LOCAL AIRE PAYROLL CERTIFICATION PASSED"
echo "Cornerstone API: $CORNERSTONE_BASE_URL"
echo "AIRE API: $AIRE_BASE_URL"
echo "Synthetic pay period ID: $PAY_PERIOD_ID"
echo "Synthetic next pay period ID: $NEXT_PAY_PERIOD_ID"

if [[ "$KEEP_RUNNING" == "true" ]]; then
  echo "Servers are being kept open for browser review. Press Ctrl-C to clean up."
  wait "$AIRE_PID" "$CORNERSTONE_PID"
fi
