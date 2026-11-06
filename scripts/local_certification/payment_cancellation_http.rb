# frozen_string_literal: true

require "json"
require "net/http"
require "open3"
require "securerandom"

directory = File.dirname(ENV.fetch("CERTIFICATION_CLOCK_FILE"))
stat = File.lstat(directory)
abort "Unsafe payment certification fixture" unless stat.directory? && stat.uid == Process.uid &&
  (stat.mode & 0o077).zero? && File.basename(directory).start_with?("cornerstone-aire-certification.")
payroll = JSON.parse(File.read(File.join(directory, "cornerstone.json")))
aire = JSON.parse(File.read(File.join(directory, "aire.json")))
policy = JSON.parse(File.read(ENV.fetch("CERTIFICATION_POLICY_FIXTURE_PATH")))
base = URI.parse(ENV.fetch("CORNERSTONE_BASE_URL"))
abort "Payment certification only calls a local API" unless base.scheme == "http" &&
  %w[localhost 127.0.0.1].include?(base.host) && base.path.empty? && base.userinfo.nil? && base.query.nil?
root = File.expand_path("../..", __dir__)
checkpoint = lambda do |application, action|
  result_path = File.join(directory, "payment-result-#{SecureRandom.hex(8)}.json")
  app_dir = application == "aire" ? File.join(ENV.fetch("AIRE_REPO_PATH"), "backend") : File.join(root, "api")
  environment = { "ROOT_DIR" => root, "PAYMENT_APP_DIR" => app_dir,
    "PAYMENT_RUBY_BIN" => ENV[application == "aire" ? "AIRE_RUBY_BIN_DIR" : "PAYROLL_RUBY_BIN_DIR"].to_s,
    "PAYMENT_DATABASE_URL" => ENV.fetch(application == "aire" ? "AIRE_DATABASE_URL" : "CORNERSTONE_DATABASE_URL"),
    "PAYMENT_ACTION" => action, "PAYMENT_RESULT_FILE" => result_path,
    "AUTH_ENABLED" => "false", "PAYROLL_SHARED_SECRET" => aire.fetch("shared_secret") }
  stdout, stderr, status = Open3.capture3(environment, "bash", "-c", <<~'SHELL')
    set -euo pipefail
    source "$ROOT_DIR/scripts/local_certification/runtime.sh"
    cd "$PAYMENT_APP_DIR"
    certification_use_ruby "$PAYMENT_APP_DIR" "$PAYMENT_RUBY_BIN"
    certification_use_clock "$PAYMENT_DATABASE_URL"
    exec bundle exec rails runner "$ROOT_DIR/scripts/local_certification/payment_checkpoint.rb"
  SHELL
  unless status.success?
    path = File.join(directory, "payment-failure-#{SecureRandom.hex(8)}.log")
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(stdout + stderr) }
    abort "Payment #{action} checkpoint failed; private diagnostic path #{path}"
  end
  JSON.parse(File.read(result_path))
end
api = lambda do |method, path, expected, body|
  uri = URI.join(base.to_s, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Content-Type"] = "application/json"
  request["X-E2E-User-Email"] = payroll.fetch("manual_accountant_email")
  request["X-Company-Id"] = payroll.fetch("company_id").to_s
  request.body = JSON.generate(body)
  response = Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 30) { |http| http.request(request) }
  abort "Payment #{method} expected #{expected}, received #{response.code}" unless response.code.to_i == expected
  JSON.parse(response.body)
end
assert = lambda { |condition, message| abort "Payment certification: #{message}" unless condition }
selection = checkpoint.call("payroll", "select")
File.open(File.join(directory, "payment-candidates.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
  file.write(JSON.generate(selection))
end
before_source = checkpoint.call("aire", "source")
selection.each do |kind, row|
  path = "/api/v1/admin/pay_periods/#{row.fetch('pay_period_id')}/payroll_items/#{row.fetch('id')}/payment_method"
  body = { payment_delivery_method: "direct_deposit", reason: "Synthetic original check recovered and cancelled for replacement bank payment",
    confirm_not_paid: true, retire_existing_check: true, confirm_check_cancelled: true,
    cancellation_evidence_reference: "SYNTHETIC-CANCEL-#{kind}", expected_check_number: row.fetch("check_number") }
  api.call("patch", path, 200, body)
end
checkpoint.call("payroll", "flush")
held = checkpoint.call("aire", "source")
assert.call(held.dig("direct", "states") == ["committed"] && held.dig("direct", "hours") == before_source.dig("direct", "hours"), "direct cancellation lost reserved coverage")
assert.call(held.dig("manual", "status") == "committed" && held.dig("manual", "reference").nil?, "manual cancellation retained the cancelled payment")
assert.call(held.dig("direct", "row_digest") == before_source.dig("direct", "row_digest"), "frozen source facts changed")
assert.call(held.dig("manual", "regular") == before_source.dig("manual", "regular") && held.dig("manual", "overtime") == before_source.dig("manual", "overtime"), "manual source split changed")
selection.each do |kind, row|
  api.call("post", "/api/v1/admin/payroll_items/#{row.fetch('id')}/direct_deposit/confirm_payment", 200,
    { settled_on: policy.fetch("delivery_date"), bank_reference: "SYNTHETIC-BANK-#{kind}", attestation: true })
end
checkpoint.call("payroll", "flush")
paid = checkpoint.call("aire", "source")
after = checkpoint.call("payroll", "native")
selection.each do |kind, row|
  assert.call(after.dig(kind, "financial_digest") == row.fetch("financial_digest") && after.dig(kind, "committed") && !after.dig(kind, "voided"), "native payroll money or obligation changed")
  assert.call(after.dig(kind, "confirmation_count") == 1, "bank confirmation duplicated")
  api.call("patch", "/api/v1/admin/pay_periods/#{row.fetch('pay_period_id')}/payroll_items/#{row.fetch('id')}/payment_method", 422,
    { payment_delivery_method: "paper_check", reason: "Synthetic refused second instrument", confirm_not_paid: true, expected_check_number: nil })
end
assert.call(paid.dig("direct", "states") == ["issued"] && paid.dig("direct", "methods") == ["direct_deposit"], "replacement direct receipt did not issue exactly")
assert.call(paid.dig("manual", "status") == "issued" && paid.dig("manual", "method") == "direct_deposit" && paid.dig("manual", "reference") == "SYNTHETIC-BANK-manual", "replacement manual receipt did not issue exactly")
assert.call(paid.dig("manual", "events") == %w[committed issued payment_cancelled issued], "manual lifecycle duplicated or lost original evidence")
checkpoint.call("payroll", "flush")
assert.call(checkpoint.call("aire", "source") == paid, "retry duplicated source payment evidence")
puts "PASS: direct/manual cancelled instruments retain committed source hours, exact bank replacements issue once, confirmed transfers block another instrument, money and frozen facts unchanged"
