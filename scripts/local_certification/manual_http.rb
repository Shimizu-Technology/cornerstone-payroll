# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "securerandom"
require "bigdecimal"

# Control-plane Ruby keeps real time. All Rails children select their own pinned
# bundle and guarded shared test clock through runtime.sh.
directory = File.dirname(ENV.fetch("CERTIFICATION_CLOCK_FILE"))
stat = File.lstat(directory)
abort "Manual certification requires a private fixture" unless stat.directory? && stat.uid == Process.uid &&
  (stat.mode & 0o077).zero? && File.basename(directory).start_with?("cornerstone-aire-certification.")
payroll = JSON.parse(File.read(File.join(directory, "cornerstone.json")))
aire = JSON.parse(File.read(File.join(directory, "aire.json")))
policy = JSON.parse(File.read(ENV.fetch("CERTIFICATION_POLICY_FIXTURE_PATH")))
base = URI.parse(ENV.fetch("CORNERSTONE_BASE_URL"))
abort "Manual certification only calls the local API" unless base.scheme == "http" &&
  %w[localhost 127.0.0.1].include?(base.host) && base.path.empty? && base.userinfo.nil? && base.query.nil?
root = File.expand_path("../..", __dir__)

private_json = lambda do |value|
  path = File.join(directory, "manual-#{SecureRandom.hex(8)}.json")
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(value)) }
  path
end
checkpoint = lambda do |application, action, extra = {}|
  application_dir = application == "aire" ? File.join(ENV.fetch("AIRE_REPO_PATH"), "backend") : File.join(root, "api")
  output = File.join(directory, "manual-result-#{SecureRandom.hex(8)}.json")
  environment = {
    "ROOT_DIR" => root, "MANUAL_APP_DIR" => application_dir, "MANUAL_ACTION" => action,
    "MANUAL_RESULT_FILE" => output,
    "MANUAL_RUBY_BIN" => ENV[application == "aire" ? "AIRE_RUBY_BIN_DIR" : "PAYROLL_RUBY_BIN_DIR"].to_s,
    "MANUAL_DATABASE_URL" => ENV.fetch(application == "aire" ? "AIRE_DATABASE_URL" : "CORNERSTONE_DATABASE_URL"),
    "AUTH_ENABLED" => "false", "PAYROLL_SHARED_SECRET" => aire.fetch("shared_secret")
  }.merge(extra)
  stdout, stderr, status = Open3.capture3(environment, "bash", "-c", <<~'SHELL')
    set -euo pipefail
    source "$ROOT_DIR/scripts/local_certification/runtime.sh"
    cd "$MANUAL_APP_DIR"
    certification_use_ruby "$MANUAL_APP_DIR" "$MANUAL_RUBY_BIN"
    certification_use_clock "$MANUAL_DATABASE_URL"
    exec bundle exec rails runner "$ROOT_DIR/scripts/local_certification/manual_checkpoint.rb"
  SHELL
  unless status.success?
    log_path = File.join(directory, "manual-failure-#{SecureRandom.hex(8)}.log")
    File.open(log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(stdout + stderr) }
    abort "Manual #{action} checkpoint failed; private diagnostic path #{log_path}"
  end
  JSON.parse(File.read(output))
end
api = lambda do |method, path, expected, body = nil|
  uri = URI.join(base.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Content-Type"] = "application/json"
  request["X-E2E-User-Email"] = payroll.fetch("manual_accountant_email")
  request["X-Company-Id"] = payroll.fetch("company_id").to_s
  request.body = JSON.generate(body) if body
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(request) }
  abort "Manual #{method} #{path} expected #{expected}, received #{response.code}" unless response.code.to_i == expected
  JSON.parse(response.body)
end
assert = lambda { |condition, message| abort "Manual certification: #{message}" unless condition }
decimal = lambda { |value| BigDecimal(value.to_s) }
review_path = lambda { |period| "/api/v1/admin/pay_periods/#{period}/aire_payroll_cockpit/manual_review" }
allocation_path = lambda { |period| "/api/v1/admin/pay_periods/#{period}/aire_payroll_cockpit/manual_allocations" }
source_adjustment = lambda do |review, entry_id|
  employee = review.fetch("employees").find { |row| row["source_user_uuid"] == aire.fetch("manual_employee_uuid") }
  Array(employee&.fetch("adjustments", [])).find { |row| row["source_time_entry_id"].to_s == entry_id.to_s }
end
request_for = lambda do |item, source, regular, overtime|
  { payroll_item_id: item, source_time_entry_id: source.fetch("source_time_entry_id"),
    source_time_entry_version: source.fetch("source_time_entry_version"), source_user_uuid: aire.fetch("manual_employee_uuid"),
    original_work_date: source.fetch("original_work_date"), regular_hours: regular, overtime_hours: overtime,
    note: "Synthetic accountant reviewed the exact source hours against this existing check" }
end

if ARGV == ["--configure-browser-profile"]
  checkpoint.call("payroll", "browser_profile")
  puts "PASS: isolated accountant selected the synthetic printer profile without configuration privileges"
  exit
end
if ARGV == ["--verify-browser"]
  local = checkpoint.call("payroll", "browser_payroll_verify")
  remote = checkpoint.call("aire", "browser_verify").fetch("allocations")
    .find { |row| row["source_time_entry_id"] == aire.fetch("manual_browser_entry_id").to_s }
  assert.call(remote["id"].to_s == local["remote_allocation_id"] &&
    %w[external_payroll_item_id payment_reference payment_effective_on].all? { |key| remote[key] == local[key] },
    "browser source receipt differs from the actual Payroll check delivery")
  %w[aire payroll].each { |application| checkpoint.call(application, "original_verify") }
  puts "PASS: browser manual source has one exact4REG/0OT issued receipt; original connected evidence unchanged"
  exit
end
abort "Unknown manual certification option" unless ARGV.empty?

%w[aire payroll].each { |application| checkpoint.call(application, "original_capture") }

# Exercise the actual two-API own-account consent protocol with explicitly
# synthetic test principals. This does not certify a human's Clerk sign-in.
link_path = "/api/v1/admin/time_tracking_sources/#{payroll.fetch('source_id')}/aire_account_link"
api.call("delete", link_path, 200)
assert.call(api.call("get", link_path, 200).dig("account_link", "connected") == false,
  "disconnected accountant still has an active account link")
session = api.call("post", link_path, 201, { external_actor_id: "must-not-be-used", external_actor_email: "wrong@example.test" })
authorization = URI.parse(session.fetch("authorization_url"))
assert.call(authorization.scheme == "http" && authorization.host == "localhost" && authorization.port == 44340 &&
  authorization.path == "/admin/payroll-link", "unexpected local account-link destination")
token = URI.decode_www_form(authorization.query.to_s).to_h.fetch("token")
aire_base = URI.parse(ENV.fetch("AIRE_BASE_URL"))
assert.call(aire_base.scheme == "http" && %w[localhost 127.0.0.1].include?(aire_base.host) &&
  aire_base.path.empty? && aire_base.userinfo.nil? && aire_base.query.nil?, "unsafe local AIRE consent API")
consent = lambda do |method, suffix, expected|
  uri = URI.join(aire_base.to_s, "/api/v1/payroll/account_link_sessions/#{token}#{suffix}")
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Bearer test_token_#{aire.fetch('manual_authority_id')}"
  request["Content-Type"] = "application/json"
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(request) }
  abort "Synthetic own-account consent expected #{expected}, received #{response.code}" unless response.code.to_i == expected
  JSON.parse(response.body)
end
details = consent.call("get", "", 200).fetch("account_link_session")
assert.call(details.fetch("external_actor_email") == payroll.fetch("manual_accountant_email"),
  "account-link identity was not pinned to the signed-in accountant")
callback = URI.parse(details.fetch("return_url"))
assert.call(callback.scheme == "http" && callback.host == "localhost" &&
  callback.port == Integer(ENV.fetch("CONNECTED_WEB_PORT", "44339")) &&
  callback.path == "/app/time-account-connection" &&
  URI.decode_www_form(callback.query.to_s).to_h["source_id"] == payroll.fetch("source_id").to_s,
  "own-account callback lost its source context")
consent.call("post", "/authorize", 200)
assert.call(api.call("get", link_path, 200).dig("account_link", "connected") == true,
  "AIRE consent did not activate the accountant's own link")
puts "PASS: synthetic assigned accountant connected own AIRE identity through both APIs; actor spoof ignored and legacy fallback removed"

periods = payroll.fetch("manual_pay_period_ids")
review = api.call("get", review_path.call(periods.first), 200)
assert.call(review.dig("command_access", "can_manage_manual_allocations") == true, "assigned accountant cannot reconcile")
source = source_adjustment.call(review, aire.fetch("manual_entry_id"))
assert.call(source && decimal.call(source["regular_hours"]) == 8 && decimal.call(source["overtime_hours"]) == 2,
  "approved unbatched manual source must be8REG/2OT")
# Reconciliation authority must not grant unrelated source/client configuration.
api.call("patch", "/api/v1/admin/time_tracking_sources/#{payroll.fetch('source_id')}", 403,
  { time_tracking_source: { name: "Must remain forbidden" } })

items = periods.each_with_index.map do |period, index|
  regular, overtime = index == 2 ? [2, 0] : [4, 1]
  response = api.call("post", "/api/v1/admin/pay_periods/#{period}/payroll_items", 201,
    { employee_id: payroll.fetch("manual_employee_id"), payroll_item: { hours_worked: regular, overtime_hours: overtime } })
  item = response.fetch("payroll_item").fetch("id")
  calculation = api.call("post", "/api/v1/admin/pay_periods/#{period}/run_payroll", 200)
  assert.call(calculation.dig("results", "errors") == [], "manual payroll calculation failed")
  row = calculation.fetch("pay_period").fetch("payroll_items").find { |candidate| candidate["id"] == item }
  assert.call(decimal.call(row["hours_worked"]) == regular && decimal.call(row["overtime_hours"]) == overtime &&
    decimal.call(row["gross_pay"]) == regular * 25 + overtime * BigDecimal("37.5"), "manual REG/OT or gross changed")
  api.call("post", "/api/v1/admin/pay_periods/#{period}/approve", 200)
  api.call("post", "/api/v1/admin/pay_periods/#{period}/commit", 200)
  api.call("post", "/api/v1/admin/payroll_items/#{item}/check/mark_printed", 200)
  item
end
puts "PASS: assigned accountant manually entered, calculated, committed and prepared three isolated checks without configuration rights"

stale = request_for.call(items.first, source, "4.00", "1.00")
checkpoint.call("aire", "source_edit")
api.call("post", allocation_path.call(periods.first), 422, stale)
review = api.call("get", review_path.call(periods.first), 200)
source = source_adjustment.call(review, aire.fetch("manual_entry_id"))
assert.call(source["source_time_entry_version"] != stale[:source_time_entry_version], "source version did not change")
api.call("post", allocation_path.call(periods.first), 422, request_for.call(items.first, source, "5.00", "1.00"))
first_request = request_for.call(items.first, source, "4.00", "1.00")
api.call("post", allocation_path.call(periods.first), 422, first_request.merge(source_user_uuid: SecureRandom.uuid))
first = api.call("post", allocation_path.call(periods.first), 201, first_request).fetch("manual_allocation")
assert.call(first["status"] == "committed", "prepared check was falsely issued or link failed")
pending_row = api.call("get", review_path.call(periods.first), 200).fetch("cornerstone_manual_allocations")
  .find { |row| row["id"] == first.fetch("id") }
assert.call(!pending_row.key?("payment_evidence"), "prepared check acquired fabricated issuance evidence")
api.call("post", allocation_path.call(periods.first), 422, first_request)
remaining = source_adjustment.call(api.call("get", review_path.call(periods.first), 200), aire.fetch("manual_entry_id"))
assert.call(remaining && decimal.call(remaining["regular_hours"]) == 4 && decimal.call(remaining["overtime_hours"]) == 1,
  "partial allocation lost or reoffered committed hours")
remote = checkpoint.call("aire", "remote_state").fetch("allocations")
assert.call(remote.size == 1 && remote.first["status"] == "committed" && remote.first["payment_reference"].nil?,
  "duplicate or rejected link wrote a source payment")
puts "PASS: accountant stale identity/version, duplicate and capacity rejects; partial committed hours excluded without inferring payment"

deliver = lambda do |item, allocation_id|
  result = api.call("post", "/api/v1/admin/payroll_items/#{item}/check/mark_delivered", 200,
    { delivered_on: policy.fetch("delivery_date"), delivery_method: "hand_delivery", attestation: true,
      evidence_reference: "SYNTHETIC-MANUAL-CERTIFICATION", note: "Synthetic delivery proof; not an actual payment" })
  synced = checkpoint.call("payroll", "sync", "MANUAL_ALLOCATION_ID" => allocation_id.to_s)
  assert.call(synced["status"] == "issued", "actual delivery did not drive issued state")
  result
end
first_delivery = deliver.call(items.first, first.fetch("id"))
remote = checkpoint.call("aire", "remote_state").fetch("allocations").first
assert.call(remote["status"] == "issued" && remote["payment_effective_on"] == policy.fetch("delivery_date") &&
  remote["payment_reference"] == first_delivery.dig("data", "payroll_item", "check_number") &&
  remote["source_user_uuid"] == aire.fetch("manual_employee_uuid") && remote["events"] == %w[committed issued],
  "exact issued source receipt missing")
issued_row = api.call("get", review_path.call(periods.first), 200).fetch("cornerstone_manual_allocations")
  .find { |row| row["id"] == first.fetch("id") }
assert.call(issued_row.fetch("payment_evidence") == {
  "reference" => remote.fetch("payment_reference"), "effective_on" => remote.fetch("payment_effective_on"),
  "provenance" => "aire_issued_receipt"
}, "operator review did not display the exact immutable AIRE receipt")

# A real remote commit succeeds; only its acknowledgement is lost in a guarded
# disposable runner. The HTTP retry must recover the same immutable command.
second_request = request_for.call(items.fetch(1), remaining, "4.00", "1.00")
pending = checkpoint.call("payroll", "ambiguous_commit", "MANUAL_REQUEST_FILE" => private_json.call(second_request))
assert.call(pending["status"] == "pending_commit", "ambiguous commit was not retained")
remote = checkpoint.call("aire", "remote_state").fetch("allocations")
assert.call(remote.size == 2 && remote.last["status"] == "committed", "lost reply did not follow a real AIRE commit")
second = api.call("post", "#{allocation_path.call(periods.fetch(1))}/#{pending.fetch('id')}/retry", 200).fetch("manual_allocation")
assert.call(second["status"] == "committed", "retry did not recover original source acknowledgement")
api.call("post", "#{allocation_path.call(periods.fetch(1))}/#{pending.fetch('id')}/retry", 200)
assert.call(checkpoint.call("aire", "remote_state").fetch("allocations").size == 2, "retry duplicated source allocation")
second_delivery = deliver.call(items.fetch(1), second.fetch("id"))
remote = checkpoint.call("aire", "remote_state").fetch("allocations")
assert.call(remote.size == 2 && remote.all? { |row| row["status"] == "issued" && row["events"] == %w[committed issued] } &&
  remote.sum { |row| decimal.call(row["regular_hours"]) } == 8 && remote.sum { |row| decimal.call(row["overtime_hours"]) } == 2,
  "split checks did not issue exact hours once")
assert.call(remote.last["payment_reference"] == second_delivery.dig("data", "payroll_item", "check_number") &&
  remote.last["payment_effective_on"] == policy.fetch("delivery_date"), "second payment lost its exact check reference/date")
assert.call(source_adjustment.call(api.call("get", review_path.call(periods.first), 200), aire.fetch("manual_entry_id")).nil?,
  "paid manual hours were offered again")
puts "PASS: two exact partial checks issued once over real HTTP; lost-response retry recovered the original immutable source receipt"

void_source = source_adjustment.call(api.call("get", review_path.call(periods.last), 200), aire.fetch("manual_void_entry_id"))
void_allocation = api.call("post", allocation_path.call(periods.last), 201,
  request_for.call(items.last, void_source, "2.00", "0.00")).fetch("manual_allocation")
api.call("post", "/api/v1/admin/payroll_items/#{items.last}/void", 200,
  { reason: "Synthetic undelivered check cancelled before any payment" })
checkpoint.call("payroll", "sync", "MANUAL_ALLOCATION_ID" => void_allocation.fetch("id").to_s)
remote_void = checkpoint.call("aire", "remote_state").fetch("allocations").last
assert.call(remote_void["status"] == "voided" && remote_void["payment_reference"].nil? && remote_void["events"] == %w[committed voided],
  "undelivered void was recorded as payment or not released")
returned = source_adjustment.call(api.call("get", review_path.call(periods.last), 200), aire.fetch("manual_void_entry_id"))
assert.call(returned && decimal.call(returned["regular_hours"]) == 2 && decimal.call(returned["overtime_hours"]).zero?,
  "undelivered void lost source hours")
%w[aire payroll].each { |application| checkpoint.call(application, "original_verify") }
puts "PASS: undelivered manual void restored exact unpaid hours; original connected batch/check/payroll unchanged"
