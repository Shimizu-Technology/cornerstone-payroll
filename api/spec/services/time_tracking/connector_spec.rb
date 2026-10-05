# frozen_string_literal: true

require "rails_helper"
require "webmock/rspec"

RSpec.describe TimeTracking::Connector do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "custom", authorization_origin: "https://neutral.example.com") }
  let(:identity) do
    {
      "source" => "neutral_time", "integration" => {
        "source_type" => "neutral_time", "protocol" => "shimizu_time_payroll", "protocol_version" => "1.0",
        "source_instance_id" => SecureRandom.uuid, "capabilities" => described_class::AIRE_CAPABILITIES,
        "policy_constraints" => {
          "time_zones" => [ "Pacific/Guam" ], "workweek_starts" => [ "monday" ],
          "cutoff_rules" => [ "before_pay_date" ], "frequencies" => [ "weekly" ]
        }
      }
    }
  end

  def pin!
    TimeTracking::ConnectionIdentity.verify_and_pin!(source: source, payload: identity)
  end

  def period!
    common = { company: company, source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: actor,
      confirmed_at: Time.current, effective_on: Date.new(2026, 1, 1), notes: "Operator confirmed neutral policy" }
    schedule = CompanyPaySchedule.create!(**common, frequency: "weekly", period_rule: "weekly", period_start_weekday: 1,
      pay_date_rule: "days_after_period_end", pay_date_offset_days: 5, timezone: "Pacific/Guam",
      time_tracking_cutoff_rule: "before_pay_date", time_tracking_cutoff_days: 2, payroll_cutoff_at_minutes: 1020)
    week = CompanyWorkweek.create!(**common, timezone: "Pacific/Guam", starts_on_weekday: 1, starts_at_minutes: 0)
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: week,
      start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 8), pay_date: Date.new(2026, 11, 13))
  end

  it "requires verified capabilities and producer identity for custom operations" do
    expect(source.supports?(:finalized_batch_v2)).to be(false)
    pin!
    expect(source.connector.source_identifier).to eq("neutral_time")
    expect(source.supports?(:finalized_batch_v2)).to be(true)
    expect(source.reload.source_policy_constraints).to eq(identity.dig("integration", "policy_constraints"))
  end

  it "does not grant complete payroll operations to a summary-only connection" do
    identity["integration"]["capabilities"] = [ "time_summary_v1" ]
    pin!
    expect { TimeTracking::Client.new(source).payroll_batches(start_date: "2026-11-02", end_date: "2026-11-08") }
      .to raise_error(TimeTracking::Client::Error, /does not support/)
    expect { TimeTracking::Client.new(source).create_payroll_account_link_session(external_actor_id: actor.id, external_actor_email: actor.email, return_url: "https://payroll.example.com") }
      .to raise_error(TimeTracking::Client::Error, /does not support/)
  end

  it "publishes the confirmed weekly Monday policy through the existing durable delivery path" do
    pin!
    period = period!
    allow(AirePayrollCalendarPublication).to receive(:dispatch_one!)
    result = AirePayrollCalendar::Publisher.new(pay_period: period, source: source, actor: actor,
      now: Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 9)).call
    expect(result.publication.payload).to include("cutoff_at" => "2026-11-11T17:00:00+10:00", "cutoff_days" => 2)
    expect(result.publication.payload.dig("overtime_policy", "workweek_start")).to eq("monday")
    expect(result.calendar_period.time_tracking_source).to eq(source)
  end

  it "rejects an unsupported policy before retaining a publication" do
    pin!
    period = period!
    source.update!(source_policy_constraints: identity.dig("integration", "policy_constraints").merge("workweek_starts" => [ "sunday" ]))
    expect { AirePayrollCalendar::Publisher.new(pay_period: period, source: source, actor: actor).call }
      .to raise_error(AirePayrollCalendar::Contract::Error, /has not verified support/)
    expect(source.aire_payroll_calendar_periods).to be_empty
  end

  it "rejects changed producer identifiers even when the installation UUID is unchanged" do
    pin!
    changed = identity.deep_dup
    changed["integration"]["source_type"] = "different_producer"
    expect { TimeTracking::ConnectionIdentity.verify_and_pin!(source: source, payload: changed) }
      .to raise_error(TimeTracking::ConnectionIdentity::Error, /producer identity changed/)
    expect(source.reload.remote_source_identifier).to eq("neutral_time")
  end

  it "preserves existing AIRE operation compatibility without changing its policy" do
    aire = create(:time_tracking_source, source_type: "aire_services")
    expect(aire.supports?(:finalized_batch_v2)).to be(true)
    expect(aire.connector.calendar_contract(build(:pay_period))).to be_a(AirePayrollCalendar::Contract)
  end

  it "enforces historical admission for a custom source on an existing payroll company" do
    create(:pay_period, :committed, company: company)
    expect(source.historical_reconciliation_required?).to be(true)
    expect(source.historical_reconciliation_complete?).to be(false)
  end

  it "rejects arbitrary account-link origins" do
    expect(build(:time_tracking_source, authorization_origin: "https://example.com/path")).not_to be_valid
    expect(build(:time_tracking_source, authorization_origin: "https://user:password@example.com")).not_to be_valid
  end

  it "validates a neutral producer batch without relaxing its checksum or line contract" do
    pin!
    payload = build_aire_batch_payload
    payload["source"] = "neutral_time"
    export = payload.delete("export")
    export["checksum"] = TimeTracking::CanonicalPayload.checksum(payload)
    payload["export"] = export
    validator = TimeTracking::PayrollBatchPayloadValidator.new(payload: payload,
      start_date: "2026-10-01", end_date: "2026-10-15", expected_source: source.connector.source_identifier)
    expect(validator.validate!).to eq(payload)
    payload["employees"].first["regular_hours"] = 99
    expect { validator.validate! }.to raise_error(TimeTracking::PayrollBatchPayloadValidator::Error, /checksum/)
  end

  it "accepts a generic callback only through its authenticated published connection and deduplicates replays" do
    pin!
    period = period!
    allow(AirePayrollCalendarPublication).to receive(:dispatch_one!)
    publication = AirePayrollCalendar::Publisher.new(pay_period: period, source: source, actor: actor,
      now: Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 9)).call.publication
    publication.update!(delivery_status: "delivered", delivered_at: Time.current)
    batch = build_aire_batch_payload(start_date: period.start_date.iso8601, end_date: period.end_date.iso8601,
      cutoff_at: publication.payload.fetch("cutoff_at"))
    event = build_aire_finalized_event(calendar_period: publication.aire_payroll_calendar_period, publication: publication, batch_payload: batch)
    event["source"] = "neutral_time"
    allow(AirePayrollEvent).to receive(:dispatch_one!)
    receive = ->(payload, secret = source.shared_secret) {
      AirePayrollEvents::Receiver.new(payload: payload, shared_secret: secret, idempotency_key: payload.fetch("event_id")).call
    }
    first = receive.call(event)
    expect(receive.call(event.deep_dup).created).to be(false)
    expect(first.event.time_tracking_source).to eq(source)
    expect { receive.call(event, "foreign-secret") }.to raise_error(AirePayrollEvents::Receiver::UnauthorizedError)
    changed = event.deep_dup
    changed["source"] = "aire_services"
    expect { receive.call(changed) }.to raise_error(AirePayrollEvents::Receiver::Error, /Unsupported event source/)
    expect(AirePayrollEvent.where(time_tracking_source: source).count).to eq(1)
  end

  it "delivers a saved queued exact-line acknowledgement for a neutral producer" do
    pin!
    period = create(:pay_period, company: company)
    import = create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source, status: "applied")
    employee = create(:employee, company: company)
    item = create(:payroll_item, pay_period: period, employee: employee)
    allocation = TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source,
      time_tracking_import: import, pay_period: period, payroll_item: item, employee: employee,
      source_user_id: "42", source_user_uuid: SecureRandom.uuid, source_time_entry_id: "101",
      line_key: "work:2500", source_kind: "current", original_work_date: period.start_date,
      total_hours: 10, regular_hours: 8, overtime_hours: 2)
    acknowledgement = AirePayrollEntryAcknowledgement.record_from_rows!(rows: [ allocation ],
      source_event_key: "neutral:101:issued", status: "payment_issued", occurred_at: Time.current,
      payroll_item_id: item.id, payment_method: "paper_check", payment_reference: "5001", payment_effective_on: period.pay_date)
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    expect(client).to receive(:record_payroll_entry_processing_event).with(hash_including(
      source_time_entry_id: "101", source_line_key: "work:2500", regular_hours: "8.0", overtime_hours: "2.0",
      payment_reference: "5001", event_id: acknowledgement.event_id)).and_return(true)
    AirePayrollEntryStatusSyncJob.perform_now(acknowledgement.id)
    expect(acknowledgement.reload.delivered_at).to be_present
  end

  it "sends neutral actor headers and rejects an unauthorized account-link destination" do
    pin!
    policy = TimeTracking::DestinationPolicy.new(environment: "test", resolver: ->(_host) { [ "8.8.8.8" ] })
    client = TimeTracking::Client.new(source, actor: actor, destination_policy: policy)
    stub_request(:get, "https://time.example.com/api/v1/payroll/cockpit/manual_review?start_date=2026-11-02&end_date=2026-11-08")
      .with(headers: { "X-Payroll-Actor-Id" => actor.id.to_s, "X-Payroll-Source-Instance-Id" => source.expected_source_instance_id })
      .to_return(status: 200, body: identity.to_json, headers: { "Content-Type" => "application/json" })
    expect(client.payroll_cockpit_manual_review(start_date: "2026-11-02", end_date: "2026-11-08")).to eq(identity)
    stub_request(:post, "https://time.example.com/api/v1/payroll/account_link_sessions")
      .to_return(status: 200, body: identity.merge(authorization_url: "https://foreign.example.com/link?token=example").to_json,
        headers: { "Content-Type" => "application/json" })
    expect { client.create_payroll_account_link_session(external_actor_id: actor.id, external_actor_email: actor.email,
      return_url: "https://payroll.example.com/app/time-account-connection") }
      .to raise_error(TimeTracking::Client::Error, /unapproved account-link URL/)
  end
  it "requires historical admission when a previously verified summary connection enables complete payroll" do
    identity["integration"]["capabilities"] = [ "time_summary_v1" ]
    pin!
    create(:pay_period, :committed, company: company)
    expect(source.reload.historical_reconciliation_required?).to be(false)
    identity["integration"]["capabilities"] = described_class::AIRE_CAPABILITIES
    pin!
    expect(source.reload.historical_reconciliation_required?).to be(true)
    expect(source.historical_reconciliation_complete?).to be(false)
  end

  it "rejects changed or missing descriptors before accepting a custom calendar acknowledgement" do
    pin!
    policy = TimeTracking::DestinationPolicy.new(environment: "test", resolver: ->(_host) { [ "8.8.8.8" ] })
    client = TimeTracking::Client.new(source, destination_policy: policy)
    endpoint = "https://time.example.com/api/v1/payroll/calendar_periods/#{SecureRandom.uuid}"
    id = endpoint.split("/").last
    [ {}, identity.deep_merge("integration" => { "source_instance_id" => SecureRandom.uuid }),
      identity.deep_merge("integration" => { "capabilities" => [ "time_summary_v1" ] }) ].each do |body|
      stub_request(:put, endpoint).to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
      expect { client.publish_payroll_calendar_period(external_pay_period_id: id, payload: {}, idempotency_key: "test") }
        .to raise_error(TimeTracking::Client::Error, /identity|contract/)
    end
    stub_request(:put, endpoint).to_return(status: 200, body: identity.to_json, headers: { "Content-Type" => "application/json" })
    expect(client.publish_payroll_calendar_period(external_pay_period_id: id, payload: {}, idempotency_key: "test")).to eq(identity)
  end

  it "provides only validated adapter-owned employee navigation" do
    aire = create(:time_tracking_source, source_type: "aire_services")
    expect(aire.connector.employee_evidence_path(employee_id: "42", period_id: "2026-10-01", entry_id: "101"))
      .to eq("/admin/users/42?entry=101&period=2026-10-01&tab=hours")
    expect(aire.connector.employee_evidence_path(employee_id: "42/foreign")).to be_nil
    expect(aire.connector.employee_evidence_path(employee_id: "42", period_id: "2026-10-01&token=secret")).to be_nil
    pin!
    expect(source.connector.employee_evidence_path(employee_id: "42")).to be_nil
  end

  it "binds paginated employee evidence to both the installation and requested employee" do
    identity["integration"]["capabilities"] += [ "employee_period_evidence_v1" ]
    pin!
    uuid = SecureRandom.uuid
    envelope = identity.except("source").merge("contract_version" => "1.0",
      "employee" => { "id" => "42", "payroll_integration_id" => uuid }, "period" => { "id" => "2026-10-01" })
    policy = TimeTracking::DestinationPolicy.new(environment: "test", resolver: ->(_host) { [ "8.8.8.8" ] })
    client = TimeTracking::Client.new(source, actor: actor, destination_policy: policy)
    endpoint = "https://time.example.com/api/v1/payroll/cockpit/employees/42/periods/2026-10-01"
    stub = stub_request(:get, endpoint).with(query: { "source_user_uuid" => uuid, "start_date" => "2026-10-01",
      "end_date" => "2026-10-15", "detail_per_page" => "25", "detail_cursor" => "signed-page" })
    stub.to_return(status: 200, body: envelope.to_json, headers: { "Content-Type" => "application/json" })
    fetch = -> { client.payroll_employee_period(employee_id: "42", period_id: "2026-10-01", source_user_uuid: uuid,
      start_date: "2026-10-01", end_date: "2026-10-15", detail_per_page: 25, detail_cursor: "signed-page") }
    expect(fetch.call).to eq(envelope)
    stub.to_return(status: 200, body: envelope.deep_merge("employee" => { "id" => "99" }).to_json,
      headers: { "Content-Type" => "application/json" })
    expect { fetch.call }.to raise_error(TimeTracking::Client::Error, /requested identity/)
  end

  it "rejects employee mapping associations across client connections" do
    foreign_source = create(:time_tracking_source)
    employee = create(:employee, company: company)
    mapping = TimeTrackingEmployeeMapping.new(company: company, time_tracking_source: foreign_source, employee: employee, source_user_id: "42")
    expect(mapping).not_to be_valid
    expect(mapping.errors[:time_tracking_source]).to include("must belong to the same company")
    expect { TimeTrackingEmployeeMapping.resolve_source_identity!(company: company, source: foreign_source,
      source_user_id: "42", source_user_uuid: SecureRandom.uuid) }.to raise_error(TimeTrackingEmployeeMapping::IdentityConflict, /does not belong/)
  end

  it "does not restart historical onboarding when a complete connection restores its capabilities" do
    pin!
    period = create(:pay_period, :committed, company: company)
    create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period)
    source.update!(source_capabilities: [ "time_summary_v1" ])
    pin!
    expect(source.reload.historical_reconciliation_required?).to be(false)
    expect(source.supports?(:payroll_calendar_v2)).to be(true)
  end
end
