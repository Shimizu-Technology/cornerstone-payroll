# frozen_string_literal: true

# Runs only against a newly created disposable certification database. The
# producer is a separate Python HTTP process, never a stubbed Ruby client.
require "json"
require "digest"
require "pathname"
require "net/http"
require "active_support/testing/time_helpers"
require "factory_bot_rails"

database = ActiveRecord::Base.connection_db_config.database.to_s
unless Rails.env.test? && ENV["CONNECTOR_CERTIFICATION"] == "disposable_test_only" &&
    database.start_with?("cornerstone_neutral_certification_") && Company.count.zero?
  abort "Refusing independent connector certification outside an empty disposable test database"
end

FactoryBot.find_definitions unless FactoryBot.factories.registered?(:company)
include ActiveSupport::Testing::TimeHelpers
config = JSON.parse(File.read(ENV.fetch("NEUTRAL_PRODUCER_CONFIG")))
base_url = ENV.fetch("NEUTRAL_PRODUCER_URL")
abort "Fixture must use an unprivileged localhost endpoint" unless base_url.match?(%r{\Ahttp://localhost:\d{4,5}\z})

def check!(condition, message)
  abort "Independent connector certification failed: #{message}" unless condition
  puts "PASS: #{message}"
end

travel_to(Time.iso8601(config.fetch("clock"))) do
  company = FactoryBot.create(:company, name: "Neutral Weekly Certification", pay_frequency: "weekly")
  actor = FactoryBot.create(:user, company: company, role: "org_admin")
  common = { company: company, source: "operator_confirmed", confirmation_status: "confirmed",
    confirmed_by: actor, confirmed_at: Time.current, effective_on: Date.new(2026, 1, 1),
    notes: "Synthetic independent producer certification only" }
  schedule = CompanyPaySchedule.create!(**common, frequency: "weekly", period_rule: "weekly",
    period_start_weekday: 1, pay_date_rule: "days_after_period_end", pay_date_offset_days: 5, timezone: "UTC",
    time_tracking_cutoff_rule: "before_pay_date", time_tracking_cutoff_days: 2, payroll_cutoff_at_minutes: 1020)
  week = CompanyWorkweek.create!(**common, timezone: "UTC", starts_on_weekday: 1, starts_at_minutes: 0)
  employee = FactoryBot.create(:employee, company: company, department: FactoryBot.create(:department, company: company),
    first_name: "Morgan", last_name: "Neutral", email: "neutral-worker@example.test", pay_frequency: "weekly", pay_rate: 25)
  wage = EmployeeWageRate.create!(employee: employee, label: "Operations", rate: 25, is_primary: true, active: true)
  EmployeeDocumentReadiness.seed_new_hire!(employee: employee, actor: actor)
  employee.employee_document_requirements.find_each do |requirement|
    EmployeeDocumentRequirementReviewService.new(requirement: requirement, actor: actor,
      attributes: { status: "waived", review_note: "Disposable synthetic employee",
        lock_version: requirement.lock_version }).call!
  end
  source = TimeTrackingSource.create!(company: company, name: "Neutral Weekly Time", source_type: "custom",
    base_url: base_url, shared_secret: config.fetch("shared_secret"), active: true)
  client = TimeTracking::Client.new(source)
  descriptor = client.time_summary(start_date: "2026-10-05", end_date: "2026-10-11")
  TimeTracking::ConnectionIdentity.verify_and_pin!(source: source, payload: descriptor)
  check!(source.reload.connector.source_identifier == "neutral_weekly_time", "actual HTTP handshake pins the independent producer")
  check!(!source.supports?(:manual_allocations), "unadvertised manual workflow is not granted")
  TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee,
    source_user_id: config.fetch("employee_id", 2).to_s, source_user_uuid: config.fetch("employee_uuid"))

  # AIRE can coexist in another company even when its numeric employee ID overlaps.
  other_company = FactoryBot.create(:company, name: "Independent AIRE Company")
  other_employee = FactoryBot.create(:employee, company: other_company,
    department: FactoryBot.create(:department, company: other_company))
  aire = FactoryBot.create(:time_tracking_source, company: other_company, source_type: "aire_services")
  TimeTrackingEmployeeMapping.create!(company: other_company, time_tracking_source: aire, employee: other_employee,
    source_user_id: config.fetch("employee_id", 2).to_s, source_user_uuid: SecureRandom.uuid)
  period = FactoryBot.create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: week,
    start_date: Date.new(2026, 10, 5), end_date: Date.new(2026, 10, 11), pay_date: Date.new(2026, 10, 16))
  result = AirePayrollCalendar::Publisher.new(pay_period: period, source: source, actor: actor).call
  delivery = AirePayrollCalendar::Delivery.new(publication_id: result.publication.id).call
  check!(delivery[:status] == "delivered", "weekly Monday UTC calendar crosses real HTTP and is acknowledged")
  fields = result.publication.payload
  check!(Time.iso8601(fields["cutoff_at"]) == Time.utc(2026, 10, 14, 17) && fields.dig("overtime_policy", "workweek_start") == "monday",
    "confirmed company policy is independent of AIRE's semi-monthly Sunday Guam policy")

  uri = URI("#{base_url}/__fixture/advance_to_cutoff")
  request = Net::HTTP::Post.new(uri)
  request["X-Payroll-Shared-Secret"] = config.fetch("shared_secret")
  request["Content-Type"] = "application/json"
  request.body = "{}"
  response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  check!(response.code == "200", "independent producer freezes its due calendar")
  travel_to(Time.iso8601(JSON.parse(response.body).fetch("clock")))

  import = TimeTracking::BatchImportPreviewService.new(pay_period: period, source: source).call
  check!(import.raw_payload.dig("export", "checksum").present?, "real HTTP frozen payload is checksum validated and retained")
  mapping = { source_user_id: config.fetch("employee_id", 2).to_s, employee_id: employee.id, include: true,
    wage_rate_mappings: [{ source_category_id: "1", source_category_key: "operations", source_category_name: "Operations",
      source_effective_rate_cents: 2500, employee_wage_rate_id: wage.id }] }
  applied = TimeTracking::ApplyImportService.new(import: import, mappings: [mapping], applied_by: actor).call
  check!(applied[:errors].empty?, "independent frozen batch applies through the production import service")
  item = period.payroll_items.find_by!(employee: employee)
  check!(item.hours_worked == 40 && item.overtime_hours == 5 && other_company.payroll_items.count.zero?,
    "45 original hours become 40 regular plus 5 OT without crossing company identity")
  PayrollCalculator.for(employee, item).calculate
  item.save!
  item.reload
  check!(item.gross_pay == BigDecimal("1187.50"), "payroll calculates the independent weekly overtime correctly")
  period.update!(status: "calculated")
  lifecycle = PayPeriodLifecycleService.new(pay_period: period, actor: actor)
  lifecycle.approve!
  lifecycle.commit!
  item.reload.mark_printed!(user: actor)
  travel_to(Time.utc(2026, 10, 16, 12))
  item.mark_delivered!(user: actor, delivered_on: "2026-10-16", delivery_method: "hand_delivery", attestation: true,
    evidence_reference: "NEUTRAL-CERTIFICATION-ONLY", note: "Disposable synthetic check, no actual payment")
  AirePayrollAcknowledgement.where(time_tracking_import: import).order(:id).each { |ack| AirePayrollStatusSyncJob.perform_now(ack.id) }
  acknowledgements = AirePayrollEntryAcknowledgement.where(time_tracking_import: import).order(:id)
  acknowledgements.each { |ack| AirePayrollEntryStatusSyncJob.perform_now(ack.id) }
  if acknowledgements.where(delivered_at: nil).exists?
    puts acknowledgements.where(delivered_at: nil).pluck(:status, :last_error).uniq.to_json
  end
  check!(acknowledgements.where(status: "payment_issued").count == 5 && acknowledgements.where(delivered_at: nil).count.zero?,
    "all five exact frozen lines receive issued receipts over real HTTP")
  uri = URI("#{base_url}/__fixture/evidence")
  request = Net::HTTP::Get.new(uri)
  request["X-Payroll-Shared-Secret"] = config.fetch("shared_secret")
  evidence = JSON.parse(Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }.body)
  issued = evidence.fetch("events").select { |event| event["status"] == "payment_issued" }
  allocations = TimeTrackingEntryAllocation.where(time_tracking_import: import).to_a
  line_key = ->(row) { [ row.fetch("source_user_uuid"), row.fetch("source_time_entry_id").to_s,
    row.fetch("source_line_key"), row.fetch("source_kind"), row.fetch("contract_version") ] }
  expected = allocations.to_h do |allocation|
    key = [ allocation.source_user_uuid, allocation.source_time_entry_id.to_s,
      allocation.line_key, allocation.source_kind, "2.0" ]
    [ key, allocation ]
  end
  keys = issued.map { |event| line_key.call(event) }
  check!(expected.length == 5 && keys.uniq.length == keys.length && keys.sort == expected.keys.sort,
    "every original frozen line has exactly one issued receipt")
  delivery_event = item.check_events.find_by!(event_type: "delivered")
  issued.each do |event|
    allocation = expected.fetch(line_key.call(event))
    check!(%w[total_hours regular_hours overtime_hours].all? { |field| BigDecimal(event.fetch(field).to_s) == allocation.public_send(field) } &&
      event.fetch("external_pay_period_id").to_s == period.id.to_s &&
      event.fetch("external_payroll_item_id").to_s == item.id.to_s &&
      event.fetch("metadata").fetch("company_id").to_s == company.id.to_s &&
      event.fetch("payment_method") == "paper_check" &&
      event.fetch("payment_reference").to_s == item.check_number.to_s &&
      event.fetch("payment_effective_on") == delivery_event.effective_on.iso8601,
      "issued receipt matches its immutable allocation and native delivery evidence")
  end
  result_path = Pathname.new(ENV.fetch("NEUTRAL_CERTIFICATION_RESULT")).expand_path
  abort "Certificate output must be private and outside a Git checkout" if result_path.dirname.ascend.any? { |directory| directory.join(".git").exist? }
  File.open(result_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |output| output.write(JSON.pretty_generate({
    schema_version: 1, source: source.connector.source_identifier, passed: true,
    payroll_sha: `git rev-parse HEAD`.strip, synthetic_only: true, actual_operator_acceptance: false,
    hours: { total: 45, regular: 40, overtime: 5 }, gross: item.gross_pay.to_s,
    fixture_sha256: Digest::SHA256.file(File.join(__dir__, "producer.py")).hexdigest,
    driver_sha256: Digest::SHA256.file(__FILE__).hexdigest,
    exact_issued_lines: issued.length, capabilities: source.source_capabilities,
    independent_policy: fields.except("publication_id"), actual_http_transport: true
  })) }
end

puts "INDEPENDENT CONNECTOR CERTIFICATION PASSED"
