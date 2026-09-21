# frozen_string_literal: true

require "rails_helper"
require "tempfile"

RSpec.describe TimeTracking::VerifiedHistoryRollout do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:period) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 31))
  end
  let(:item) do
    create(:payroll_item, :with_check, company: company, pay_period: period, employee: employee,
      hours_worked: 6.1, overtime_hours: 0, pay_rate: 10, gross_pay: 61, net_pay: 50)
  end
  let(:uuid) { SecureRandom.uuid }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:manifest) do
    {
      "version" => 1, "company_id" => company.id, "company_name" => company.name,
      "source_id" => source.id, "actor_id" => actor.id,
      "identity_links" => [ {
        "source_user_id" => "91", "source_user_uuid" => uuid, "employee_id" => employee.id,
        "employee_name" => employee.full_name, "employee_status" => employee.status
      } ],
      "delivered_checks" => [ {
        "payroll_item_id" => item.id, "pay_period_id" => period.id, "employee_id" => employee.id,
        "check_number" => item.check_number, "net_pay" => item.net_pay.to_s,
        "regular_hours" => "6.10", "overtime_hours" => "0.00",
        "delivered_on" => PayrollBusinessClock.today.iso8601
      } ],
      "issued_entries" => [ {
        "payroll_item_id" => item.id, "source_time_entry_id" => "41", "source_user_uuid" => uuid,
        "original_work_date" => "2026-08-14", "regular_hours" => "6.10",
        "overtime_hours" => "0.00", "category_name" => "Maintenance"
      } ],
      "classification_cases" => [],
      "finalized_batch_entries" => []
    }
  end
  let(:review) do
    { "employees" => [ {
      "source_user_uuid" => uuid,
      "adjustments" => [ {
        "source_time_entry_id" => "41", "source_time_entry_version" => 2,
        "source_kind" => "current", "original_work_date" => "2026-08-14",
        "regular_hours" => "6.10", "overtime_hours" => "0.00",
        "category" => { "name" => "Maintenance" }
      } ]
    } ] }
  end

  before do
    employee.employee_wage_rates.create!(label: "Maintenance", rate: 10, active: true, is_primary: true)
    allow(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: actor).and_return(client)
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(client).to receive(:payroll_cockpit_employees).with(employee_id: "91")
      .and_return("employees" => [ { "id" => "91", "payroll_integration_id" => uuid } ])
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(review)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => {
      "connected" => true, "aire_user_email" => actor.email
    })
    allow(client).to receive(:commit_payroll_manual_allocation)
      .and_return("manual_allocation" => { "id" => "501", "version" => 0 })
    allow(client).to receive(:issue_payroll_manual_allocation)
      .and_return("manual_allocation" => { "id" => "501", "version" => 1 })
  end

  it "preflights exact identities, checks, and source entries without writing" do
    rollout = described_class.new(manifest: manifest, actor: actor)

    expect(rollout.preview!).to include(identity_links: 1, exact_entries: 1, new_source_entries_ignored: 0)
    expect(TimeTrackingEmployeeMapping.count).to eq(0)
    expect(TimeTrackingManualAllocation.count).to eq(0)
    expect(item.check_events.deliveries.count).to eq(0)
  end

  it "authenticates a bundled encrypted manifest before parsing it" do
    key = OpenSSL::Random.random_bytes(32)
    plaintext = JSON.generate(manifest)
    cipher = OpenSSL::Cipher.new("aes-256-gcm")
    cipher.encrypt
    cipher.key = key
    nonce = OpenSSL::Random.random_bytes(12)
    cipher.iv = nonce
    cipher.auth_data = "cornerstone-aire-history-rollout-v1"
    ciphertext = cipher.update(plaintext) + cipher.final
    envelope = {
      version: 1, algorithm: "aes-256-gcm",
      nonce: Base64.strict_encode64(nonce),
      tag: Base64.strict_encode64(cipher.auth_tag),
      ciphertext: Base64.strict_encode64(ciphertext)
    }
    Tempfile.create("aire-rollout") do |file|
      file.write(JSON.generate(envelope))
      file.flush
      loaded = described_class.load_encrypted_file!(
        path: file.path, key_hex: key.unpack1("H*"), expected_sha256: Digest::SHA256.hexdigest(plaintext)
      )
      expect(loaded.fetch("identity_links")).to eq(manifest.fetch("identity_links"))
      expect { described_class.load_encrypted_file!(
        path: file.path, key_hex: "00" * 32, expected_sha256: Digest::SHA256.hexdigest(plaintext)
      ) }.to raise_error(described_class::Error, /cannot be authenticated/)
    end
  end

  it "applies verified links and issued payment evidence idempotently" do
    rollout = described_class.new(manifest: manifest, actor: actor)

    expect(rollout.apply!).to include(exact_entries: 1)
    expect(TimeTrackingEmployeeMapping.find_by!(source_user_uuid: uuid).employee_id).to eq(employee.id)
    expect(item.check_events.deliveries.count).to eq(1)
    expect(TimeTrackingManualAllocation.find_by!(source_time_entry_id: "41").status).to eq("issued")
    expect(AireVerifiedHistoryRolloutReceipt.find_by!(company: company).paid_source_entry_count).to eq(1)
    expect { described_class.new(manifest: manifest, actor: actor).apply! }
      .not_to change(TimeTrackingManualAllocation, :count)
  end

  it "holds the release when AIRE changed an exact source entry" do
    review.fetch("employees").first.fetch("adjustments").first["regular_hours"] = "6.20"

    expect { described_class.new(manifest: manifest, actor: actor).apply! }
      .to raise_error(described_class::Error, /changed or is no longer unpaid/)
    expect(TimeTrackingEmployeeMapping.count).to eq(0)
    expect(item.check_events.deliveries.count).to eq(0)
  end

  it "never treats a newly added old-period entry as paid by the historical check" do
    review.fetch("employees").first.fetch("adjustments") << {
      "source_time_entry_id" => "99", "source_time_entry_version" => 0,
      "source_kind" => "current", "original_work_date" => "2026-08-15",
      "regular_hours" => "2.00", "overtime_hours" => "0.00",
      "category" => { "name" => "Maintenance" }
    }

    summary = described_class.new(manifest: manifest, actor: actor).apply!

    expect(summary.fetch(:new_source_entries_ignored)).to eq(1)
    expect(TimeTrackingManualAllocation.pluck(:source_time_entry_id)).to eq([ "41" ])
  end

  it "sends finalized-batch payment evidence for the exact delivered check" do
    import = create(:time_tracking_import, :finalized_aire_batch,
      pay_period: period, time_tracking_source: source, status: "applied")
    TimeTrackingEntryAllocation.create!(
      company: company, time_tracking_source: source, time_tracking_import: import,
      pay_period: period, payroll_item: item, employee: employee,
      source_user_id: "91", source_user_uuid: uuid, source_time_entry_id: "41",
      original_work_date: Date.new(2026, 8, 14), line_key: "category:1", source_kind: "current",
      total_hours: 6.1, regular_hours: 6.1, overtime_hours: 0
    )
    manifest["issued_entries"] = []
    manifest["finalized_batch_entries"] = [ {
      "payroll_item_id" => item.id, "source_time_entry_id" => "41",
      "source_user_uuid" => uuid, "regular_hours" => "6.10", "overtime_hours" => "0.00"
    } ]
    allow(client).to receive(:record_payroll_entry_processing_event).and_return({ "ok" => true })

    expect(described_class.new(manifest: manifest, actor: actor).apply!)
      .to include(finalized_batch_entries: 1)
    acknowledgement = AirePayrollEntryAcknowledgement.find_by!(source_time_entry_id: "41", status: "payment_issued")
    expect(acknowledgement.payment_effective_on).to eq(PayrollBusinessClock.today)
    expect(acknowledgement.delivered_at).to be_present
    expect(described_class.new(manifest: manifest, actor: actor).apply!)
      .to include(finalized_batch_entries: 1)
    expect(AirePayrollEntryAcknowledgement.where(source_time_entry_id: "41", status: "payment_issued").count).to eq(1)
  end
end
