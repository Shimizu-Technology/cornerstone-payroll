#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AIRE_REPO_PATH="${AIRE_REPO_PATH:-}"
AIRE_PORT="${AIRE_PORT:-44327}"
CORNERSTONE_PORT="${CORNERSTONE_PORT:-44328}"
CONNECTED_WEB_PORT="${CONNECTED_WEB_PORT:-44339}"
KEEP_RUNNING="${KEEP_RUNNING:-false}"
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
CERTIFICATION_CLOCK_FILE="$TEMP_DIR/clock.epoch"
CERTIFICATION_POLICY_FIXTURE_PATH="$TEMP_DIR/policy.json"
AIRE_LOG="$TEMP_DIR/aire.log"
CORNERSTONE_LOG="$TEMP_DIR/cornerstone.log"
AIRE_PID=""
CORNERSTONE_PID=""
# A supplied runtime directory makes the drill portable to CI with two pinned Rubies.
# Local runs retain rbenv selection when no directory is supplied.
source "$ROOT_DIR/scripts/local_certification/runtime.sh"

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
[[ -f "$ROOT_DIR/api/.ruby-version" && -f "$AIRE_REPO_PATH/backend/.ruby-version" ]] || fail "both Rails applications must pin Ruby in .ruby-version"
(certification_use_ruby "$AIRE_REPO_PATH/backend" "${AIRE_RUBY_BIN_DIR:-}")
(certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}")
# Pin control-plane Ruby too; macOS may otherwise select its legacy system Ruby.
certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}"
[[ "$AIRE_DATABASE" == aire_cornerstone_certification_* ]] || fail "unsafe AIRE database name"
[[ "$CORNERSTONE_DATABASE" == cornerstone_aire_certification_* ]] || fail "unsafe Cornerstone database name"
[[ "$CONNECTED_WEB_PORT" =~ ^[0-9]{1,5}$ && "$CONNECTED_WEB_PORT" -gt 0 && "$CONNECTED_WEB_PORT" -le 65535 ]] || fail "invalid connected browser port"

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

ruby "$ROOT_DIR/scripts/local_certification/policy_fixture.rb" prepare \
  "$CERTIFICATION_POLICY_FIXTURE_PATH" "$CERTIFICATION_CLOCK_FILE"

echo "Preparing isolated local databases..."
createdb "$AIRE_DATABASE"
createdb "$CORNERSTONE_DATABASE"

(
  cd "$AIRE_REPO_PATH/backend"
  certification_use_ruby "$AIRE_REPO_PATH/backend" "${AIRE_RUBY_BIN_DIR:-}"
  certification_use_clock "$AIRE_DATABASE_URL"
  RAILS_ENV=test TEST_DATABASE_URL="$AIRE_DATABASE_URL" bundle exec rails db:schema:load
  RAILS_ENV=test E2E_TEST_MODE=true TEST_DATABASE_URL="$AIRE_DATABASE_URL" \
    PAYROLL_SHARED_SECRET="$SHARED_SECRET" CERTIFICATION_FIXTURE_PATH="$AIRE_FIXTURE" \
    bundle exec rails runner "$ROOT_DIR/scripts/local_certification/seed_aire.rb"
)

(
  cd "$ROOT_DIR/api"
  certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}"
  certification_use_clock "$CORNERSTONE_DATABASE_URL"
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
PAY_DATE="$(json_value "$CORNERSTONE_FIXTURE" pay_date)"
PREVIOUS_REGULAR_PAY_DATE="$(json_value "$CORNERSTONE_FIXTURE" previous_regular_pay_date)"
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
  certification_use_ruby "$AIRE_REPO_PATH/backend" "${AIRE_RUBY_BIN_DIR:-}"
  certification_use_clock "$AIRE_DATABASE_URL"
  exec env RAILS_ENV=test E2E_TEST_MODE=true TEST_DATABASE_URL="$AIRE_DATABASE_URL" \
    PAYROLL_SHARED_SECRET="$SHARED_SECRET" \
    FRONTEND_URL="http://localhost:44340" \
    CORNERSTONE_PAYROLL_EVENTS_URL="$CORNERSTONE_BASE_URL/api/v1/integrations/aire/events" \
    bundle exec rails server --binding 127.0.0.1 --port "$AIRE_PORT"
) >"$AIRE_LOG" 2>&1 &
AIRE_PID=$!

(
  cd "$ROOT_DIR/api"
  certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}"
  certification_use_clock "$CORNERSTONE_DATABASE_URL"
  exec env RAILS_ENV=test AUTH_ENABLED=false E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    FRONTEND_URL="http://localhost:$CONNECTED_WEB_PORT" \
    CORS_ORIGINS="http://127.0.0.1:44329,http://localhost:${CONNECTED_WEB_PORT:-44339},http://127.0.0.1:${CONNECTED_WEB_PORT:-44339}" \
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
api_call 201 "publish the previous-regular-payday calendar from Cornerstone to AIRE" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_calendar/publish" "$PUBLISH_RESPONSE"
NEXT_PUBLISH_RESPONSE="$TEMP_DIR/next-publish.json"
api_call 201 "publish the next available AIRE payroll period" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$NEXT_PAY_PERIOD_ID/aire_payroll_calendar/publish" "$NEXT_PUBLISH_RESPONSE"
(
  cd "$ROOT_DIR/api"
  certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}"
  certification_use_clock "$CORNERSTONE_DATABASE_URL"
  RAILS_ENV=test AUTH_ENABLED=false E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    bundle exec rails runner '
      publications = AirePayrollCalendarPublication.where(delivery_status: %w[pending failed]).order(:id).to_a
      abort "missing calendar publications" unless publications.size == 2
      publications.each do |publication|
        result = AirePayrollCalendar::Delivery.new(publication_id: publication.id).call
        abort "calendar delivery failed: #{result[:error]}" unless result.fetch(:status) == "delivered"
      end
      puts "PASS: both versioned calendar periods reached AIRE"
    '
)
(
  cd "$AIRE_REPO_PATH/backend"
  certification_use_ruby "$AIRE_REPO_PATH/backend" "${AIRE_RUBY_BIN_DIR:-}"
  certification_use_clock "$AIRE_DATABASE_URL"
  RAILS_ENV=test E2E_TEST_MODE=true TEST_DATABASE_URL="$AIRE_DATABASE_URL" \
    EXPECTED_PREVIOUS_REGULAR_PAY_DATE="$PREVIOUS_REGULAR_PAY_DATE" \
    EXPECTED_CURRENT_PAY_DATE="$PAY_DATE" \
    bundle exec rails runner '
      periods = PayrollCalendarPeriod.order(:start_date).to_a
      abort "expected two published calendar periods" unless periods.size == 2
      abort "calendar contract did not use schema 2.0" unless periods.all? { |period| period.schema_version == "2.0" }
      abort "calendar did not freeze weekly-only overtime" unless periods.all? do |period|
        period.overtime_policy == {
          "schema_version" => "2.0", "calculation" => "weekly_only", "weekly_threshold_hours" => 40.0,
          "workweek_start" => "sunday", "time_zone" => "Pacific/Guam"
        }
      end
      abort "calendar contract did not preserve the fixed Guam policy" unless periods.all? do |period|
        local = period.cutoff_at.in_time_zone("Pacific/Guam")
        period.cutoff_rule == "after_previous_regular_payday" && period.cutoff_days == 7 &&
          local.to_date == period.previous_regular_pay_date + 7.days && local.hour == 17 && local.min.zero? && local.sec.zero? &&
          (period.pay_date.day == 15 || period.pay_date == period.pay_date.end_of_month)
      end
      expected_previous_dates = [ ENV.fetch("EXPECTED_PREVIOUS_REGULAR_PAY_DATE"), ENV.fetch("EXPECTED_CURRENT_PAY_DATE") ]
      actual_previous_dates = periods.map { |period| period.previous_regular_pay_date.iso8601 }
      abort "calendar contract lost the target-run payday association" unless actual_previous_dates == expected_previous_dates
      puts "PASS: AIRE preserved each target run association with the previous regular payday cutoff"
    '
)

(
  cd "$ROOT_DIR/api"
  certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}"
  certification_use_clock "$CORNERSTONE_DATABASE_URL"
  RAILS_ENV=test AUTH_ENABLED=false E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    AIRE_CERTIFICATION_FIXTURE_PATH="$AIRE_FIXTURE" \
    bundle exec rails runner "$ROOT_DIR/scripts/local_certification/verify_history_contract.rb"
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
[[ "$APPROVED_OVERTIME_STATUS" == "none" ]] || fail "a long day below forty weekly hours was incorrectly flagged as overtime"
REPLAY_RESPONSE="$TEMP_DIR/approval-replay.json"
api_call 200 "replay the same delegated approval idempotently" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/time_entries/$MANUAL_APPROVE_ID/approval" \
  "$REPLAY_RESPONSE" "$APPROVAL_BODY"
ruby -rjson -e 'abort "approval was executed twice" unless JSON.parse(File.read(ARGV[0])).dig("command", "replayed") == true' "$REPLAY_RESPONSE"

ruby -rjson -e '
  entry=JSON.parse(File.read(ARGV[0])).fetch("time_entry")
  abort "approved regular time is not payable" unless entry.dig("state", "payable_now") == true
' "$APPROVAL_RESPONSE"
echo "PASS: fourteen hours in one day remain regular below forty weekly hours; manual time approved through Cornerstone"

STALE_BODY="$TEMP_DIR/stale.json"
ruby -rjson -rsecurerandom -e 'File.write(ARGV[0], JSON.generate(command_id: SecureRandom.uuid, expected_version: 99, decision: "approve", reason: "Deliberate stale-version certification"))' "$STALE_BODY"
STALE_RESPONSE="$TEMP_DIR/stale-response.json"
api_call 409 "reject a stale manual-time decision" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/time_entries/$MANUAL_HOLD_ID/approval" \
  "$STALE_RESPONSE" "$STALE_BODY"

echo "Advancing both isolated test APIs past the fixed 17:00 Guam cutoff at $CUTOFF_AT..."
ruby "$ROOT_DIR/scripts/local_certification/policy_fixture.rb" advance \
  "$CERTIFICATION_POLICY_FIXTURE_PATH" "$CERTIFICATION_CLOCK_FILE"

FINALIZE_BODY="$TEMP_DIR/finalize.json"
ruby -rjson -rsecurerandom -e 'File.write(ARGV[0], JSON.generate(command_id: SecureRandom.uuid, expected_version: 0, reason: "Reviewed readiness and locked the synthetic cutoff"))' "$FINALIZE_BODY"
FINALIZE_RESPONSE="$TEMP_DIR/finalize-response.json"
api_call 202 "lock the due AIRE period from Cornerstone" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/pay_periods/$PAY_PERIOD_ID/aire_payroll_cockpit/finalize" \
  "$FINALIZE_RESPONSE" "$FINALIZE_BODY"

echo "Delivering and verifying AIRE's immutable finalized event over local HTTP..."
(
  cd "$AIRE_REPO_PATH/backend"
  certification_use_ruby "$AIRE_REPO_PATH/backend" "${AIRE_RUBY_BIN_DIR:-}"
  certification_use_clock "$AIRE_DATABASE_URL"
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
  certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}"
  certification_use_clock "$CORNERSTONE_DATABASE_URL"
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
  abort "eligible regular hours were not 14.0" unless item.fetch("hours_worked").to_f == 14.0
  abort "a below-forty week generated overtime" unless item.fetch("overtime_hours").to_f.zero?
  abort "gross pay did not preserve all regular hours" unless item.fetch("gross_pay").to_f == 350.0
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
ruby -rjson -e 'File.write(ARGV[0], JSON.generate(delivered_on: ARGV.fetch(1), delivery_method: "hand_delivery", attestation: true, evidence_reference: "LOCAL-CERTIFICATION-ONLY", note: "Synthetic local delivery proof"))' "$DELIVERY_BODY" \
  "$(json_value "$CERTIFICATION_POLICY_FIXTURE_PATH" delivery_date)"
DELIVERY_RESPONSE="$TEMP_DIR/delivery-response.json"
api_call 200 "record synthetic check delivery as the payment event" POST \
  "$CORNERSTONE_BASE_URL/api/v1/admin/payroll_items/$PAYROLL_ITEM_ID/check/mark_delivered" \
  "$DELIVERY_RESPONSE" "$DELIVERY_BODY"

(
  cd "$ROOT_DIR/api"
  certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}"
  certification_use_clock "$CORNERSTONE_DATABASE_URL"
  RAILS_ENV=test AUTH_ENABLED=false E2E_TEST_MODE=true TEST_DATABASE_URL="$CORNERSTONE_DATABASE_URL" \
    bundle exec rails runner '
      entry_acknowledgements = AirePayrollEntryAcknowledgement.order(:id).to_a
      abort "entry acknowledgements are missing" if entry_acknowledgements.empty?
      unless entry_acknowledgements.all? do |ack|
        ack.contract_version == "2.0" &&
          ack.source_line_key.present? &&
          ack.source_kind.in?(TimeTrackingEntryAllocation::SOURCE_KINDS) &&
          ack.total_hours == ack.regular_hours + ack.overtime_hours
      end
        abort "entry acknowledgements lost exact payable-line identity or hours"
      end
      AirePayrollAcknowledgement.undelivered.order(:id).find_each { |ack| AirePayrollStatusSyncJob.perform_now(ack.id) }
      AirePayrollEntryAcknowledgement.undelivered.order(:id).find_each { |ack| AirePayrollEntryStatusSyncJob.perform_now(ack.id) }
      abort "batch acknowledgements remain" if AirePayrollAcknowledgement.undelivered.exists?
      abort "entry acknowledgements remain" if AirePayrollEntryAcknowledgement.undelivered.exists?
      puts "PASS: exact payable-line imported, committed, and paid states reached AIRE"
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
  entries.select { |entry| entry.dig("lifecycle", "status") == "payment_issued" }.each do |entry|
    settlement=entry.dig("lifecycle", "settlements")&.last
    abort "paid entry is missing its settlement" unless settlement
    abort "paid hours do not match the exact settlement" unless settlement.fetch("paid_hours").to_f == settlement.fetch("total_hours").to_f
    abort "paid entry still has outstanding hours" unless settlement.fetch("outstanding_hours").to_f.zero?
    lines=settlement.fetch("payable_lines")
    abort "paid entry is missing payable-line receipts" if lines.empty?
    unless lines.all? { |line| line.fetch("source_line_key").to_s.length.positive? && line.fetch("status") == "payment_issued" }
      abort "paid entry payable-line receipts are incomplete"
    end
  end
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

echo "Certifying the assigned-accountant manual payroll and exact payment reconciliation path..."
export CERTIFICATION_CLOCK_FILE CERTIFICATION_POLICY_FIXTURE_PATH AIRE_REPO_PATH
export AIRE_DATABASE_URL CORNERSTONE_DATABASE_URL CORNERSTONE_BASE_URL AIRE_BASE_URL
ruby "$ROOT_DIR/scripts/local_certification/manual_http.rb"

if [[ "${RUN_CONNECTED_BROWSER:-false}" == "true" ]]; then
  (
    # Browser child runners share the API's guarded clock and isolated DB. Keep
    # these Rails-only options out of the control-plane Ruby verifier below.
    certification_use_ruby "$ROOT_DIR/api" "${PAYROLL_RUBY_BIN_DIR:-}"
    certification_use_clock "$CORNERSTONE_DATABASE_URL"
    export AUTH_ENABLED=false
    E2E_CONNECTED_FIXTURE_PATH="$CORNERSTONE_FIXTURE" E2E_AIRE_FIXTURE_PATH="$AIRE_FIXTURE" \
      E2E_POLICY_FIXTURE_PATH="$CERTIFICATION_POLICY_FIXTURE_PATH" \
      E2E_API_PORT="$CORNERSTONE_PORT" E2E_AIRE_PORT="$AIRE_PORT" E2E_WEB_PORT="$CONNECTED_WEB_PORT" \
      npm --prefix "$ROOT_DIR/web" run test:e2e:connected
  )
  ruby "$ROOT_DIR/scripts/local_certification/manual_http.rb" --verify-browser
  ruby -rjson -e '
    File.write(ARGV.fetch(0), JSON.pretty_generate(
      schema_version: 1, flow: "accountant-manual-browser-v1",
      payroll_sha: ARGV.fetch(1), aire_sha: ARGV.fetch(2),
      browser_passed: true, source_receipt_verified: true
    ) + "\n")
  ' "${CONNECTED_OPERATOR_RESULT_PATH:-$TEMP_DIR/operator-result.json}" \
    "$(git -C "$ROOT_DIR" rev-parse HEAD)" "$(git -C "$AIRE_REPO_PATH" rev-parse HEAD)"
fi

ruby "$ROOT_DIR/scripts/local_certification/payment_cancellation_http.rb"

echo "LOCAL AIRE PAYROLL CERTIFICATION PASSED"
echo "Cornerstone API: $CORNERSTONE_BASE_URL"
echo "AIRE API: $AIRE_BASE_URL"
echo "Synthetic pay period ID: $PAY_PERIOD_ID"
echo "Synthetic next pay period ID: $NEXT_PAY_PERIOD_ID"

if [[ "$KEEP_RUNNING" == "true" ]]; then
  echo "Private browser fixture paths: Cornerstone=$CORNERSTONE_FIXTURE AIRE=$AIRE_FIXTURE"
  echo "Servers are being kept open for browser review. Press Ctrl-C to clean up."
  wait "$AIRE_PID" "$CORNERSTONE_PID"
fi
