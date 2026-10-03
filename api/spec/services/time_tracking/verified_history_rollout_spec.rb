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
    allow(client).to receive(:payroll_cockpit_employee).with(employee_id: "91")
      .and_return("employee" => { "id" => "91", "payroll_integration_id" => uuid, "full_name" => employee.full_name })
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

  it "rejects a local numeric employee ID belonging to another company" do
    other = create(:employee)
    manifest["identity_links"].first["employee_id"] = other.id
    manifest["identity_links"].first["employee_name"] = other.full_name
    expect { described_class.new(manifest: manifest, actor: actor).preview! }
      .to raise_error(described_class::Error, /Payroll employee .* changed/)
    expect(TimeTrackingEmployeeMapping.count).to eq(0)
  end

  it "denies an accountant an unassigned client in the same organization" do
    actor.update!(role: "accountant", company: create(:company, organization: company.organization))
    expect { described_class.new(manifest: manifest, actor: actor).preview! }
      .to raise_error(described_class::Error, /cannot approve historical reconciliation/)
    expect(TimeTrackingEmployeeMapping.count).to eq(0)
  end

  it "rejects name, source installation, and captured-version drift before applying" do
    allow(client).to receive(:payroll_cockpit_employee).and_return("employee" => {
      "id" => "91", "payroll_integration_id" => uuid, "full_name" => "Different Person"
    })
    expect { described_class.new(manifest: manifest, actor: actor).preview! }
      .to raise_error(described_class::Error, /AIRE employee .* changed/)
    manifest["source_instance_id"] = SecureRandom.uuid
    expect { described_class.new(manifest: manifest, actor: actor).preview! }
      .to raise_error(described_class::Error, /installation identity changed/)
    manifest.delete("source_instance_id")
    allow(client).to receive(:payroll_cockpit_employee).and_return("employee" => {
      "id" => "91", "payroll_integration_id" => uuid, "full_name" => employee.full_name
    })
    manifest["issued_entries"].first["source_time_entry_version"] = 3
    expect { described_class.new(manifest: manifest, actor: actor).preview! }
      .to raise_error(described_class::Error, /changed or is no longer unpaid/)
    expect(item.check_events.deliveries.count).to eq(0)
  end

  it "requires explicit manifest acceptance for production apply" do
    allow(Rails.env).to receive(:production?).and_return(true)
    expect { described_class.new(manifest: manifest, actor: actor).apply! }
      .to raise_error(described_class::Error, /accepted manifest/)
    expect(TimeTrackingEmployeeMapping.count).to eq(0)
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

  it "rejects a private manifest with the wrong checksum or unsafe permissions" do
    Tempfile.create("aire-rollout") do |file|
      file.write(JSON.generate(manifest))
      file.flush
      File.chmod(0o600, file.path)
      expect { described_class.load_file!(path: file.path, expected_sha256: "0" * 64) }
        .to raise_error(described_class::Error, /checksum differs/)
      File.chmod(0o644, file.path)
      expect { described_class.load_file!(path: file.path, expected_sha256: Digest::SHA256.file(file.path).hexdigest) }
        .to raise_error(described_class::Error, /private file/)
    end
  end

  it "rejects a different actor and entries that bypass delivered-check evidence" do
    wrong_actor = manifest.deep_dup
    wrong_actor["actor_id"] = actor.id + 1
    expect { described_class.new(manifest: wrong_actor, actor: actor).preview! }
      .to raise_error(described_class::Error, /actor differs/)

    missing_check = manifest.deep_dup
    missing_check["delivered_checks"] = []
    expect { described_class.new(manifest: missing_check, actor: actor).preview! }
      .to raise_error(described_class::Error, /no verified delivered check/)

    duplicate_path = manifest.deep_dup
    duplicate_path["finalized_batch_entries"] = [ duplicate_path.fetch("issued_entries").first ]
    expect { described_class.new(manifest: duplicate_path, actor: actor).preview! }
      .to raise_error(described_class::Error, /belongs to two paths/)
  end

  it "applies verified links and issued payment evidence idempotently" do
    review.fetch("employees") << {
      "source_user_uuid" => SecureRandom.uuid,
      "adjustments" => [ {
        "source_time_entry_id" => "outside-manifest", "source_time_entry_version" => 0,
        "source_kind" => "current", "original_work_date" => "2026-08-15",
        "regular_hours" => "2.00", "overtime_hours" => "0.00",
        "category" => { "name" => "Maintenance" }
      } ]
    }
    rollout = described_class.new(manifest: manifest, actor: actor)

    expect(rollout.apply!).to include(exact_entries: 1, new_source_entries_ignored: 1)
    expect(TimeTrackingEmployeeMapping.find_by!(source_user_uuid: uuid).employee_id).to eq(employee.id)
    expect(item.check_events.deliveries.count).to eq(1)
    expect(TimeTrackingManualAllocation.find_by!(source_time_entry_id: "41").status).to eq("issued")
    expect(AireVerifiedHistoryRolloutReceipt.find_by!(company: company).paid_source_entry_count).to eq(1)
    replay_summary = nil
    expect { replay_summary = described_class.new(manifest: manifest, actor: actor).apply! }
      .not_to change(TimeTrackingManualAllocation, :count)
    expect(replay_summary).to include(new_source_entries_ignored: 1)
  end

  it "holds the release when AIRE changed an exact source entry" do
    review.fetch("employees").first.fetch("adjustments").first["regular_hours"] = "6.00"

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
  it "requires and acknowledges every exact line when one historical source entry has multiple payable lines" do
    import = create(:time_tracking_import, :finalized_aire_batch,
      pay_period: period, time_tracking_source: source, status: "applied")
    [ [ "category:1", "3.10" ], [ "category:2", "3.00" ] ].each do |key, regular|
      TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source, time_tracking_import: import,
        pay_period: period, payroll_item: item, employee: employee, source_user_id: "91", source_user_uuid: uuid,
        source_time_entry_id: "41", original_work_date: Date.new(2026, 8, 14), line_key: key, source_kind: "current",
        total_hours: regular, regular_hours: regular, overtime_hours: 0)
    end
    manifest["issued_entries"] = []
    manifest["finalized_batch_entries"] = [ {
      "payroll_item_id" => item.id, "source_time_entry_id" => "41", "source_line_key" => "category:1",
      "source_user_uuid" => uuid, "regular_hours" => "3.10", "overtime_hours" => "0.00"
    } ]
    expect { described_class.new(manifest: manifest, actor: actor).apply! }
      .to raise_error(described_class::Error, /cover every exact payable line/)
    expect(item.check_events.deliveries.count).to eq(0)
    manifest["finalized_batch_entries"] << manifest["finalized_batch_entries"].first.merge(
      "source_line_key" => "category:2", "regular_hours" => "3.00")
    source.update!(expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "2.0", identity_verified_at: Time.current)
    source.update_column(:historical_reconciliation_required, true)
    manifest["source_instance_id"] = source.expected_source_instance_id
    manifest["history_through_work_date"] = period.end_date.iso8601
    manifest["finalized_batch_entries"].each { |row| row["source_time_entry_version"] = 2 }
    inventory_entry = { "id" => "41", "source_user_uuid" => uuid, "version" => 2, "hours" => 6.2 }
    allow(client).to receive(:payroll_cockpit_history_entries).and_return(
      "time_entries" => [ inventory_entry ],
      "pagination" => { "current_page" => 1, "total_pages" => 1, "total_count" => 1, "truncated" => false })
    digest = Digest::SHA256.hexdigest(JSON.generate(manifest))
    expect { described_class.new(manifest: manifest, actor: actor).apply!(
      accepted_manifest_sha256: digest, release_owner: "Approved test owner") }
      .to raise_error(described_class::Error, /without a verified disposition/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    inventory_entry["hours"] = 6.1
    allow(client).to receive(:record_payroll_entry_processing_event).and_return({ "ok" => true })
    expect(described_class.new(manifest: manifest, actor: actor).apply!(
      accepted_manifest_sha256: digest, release_owner: "Approved test owner")).to include(finalized_batch_entries: 2)
    expect(source.historical_reconciliation_complete?).to be(true)
    expect(item.aire_payroll_entry_acknowledgements.where(status: "payment_issued").pluck(:source_line_key).sort)
      .to eq(%w[category:1 category:2])
  end

  it "rejects old scope and does not certify entries left outside approved dispositions" do
    source.update!(expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "2.0", identity_verified_at: Time.current)
    manifest["source_instance_id"] = source.expected_source_instance_id
    manifest["history_through_work_date"] = (period.end_date - 1).iso8601
    expect { described_class.new(manifest: manifest, actor: actor).preview! }
      .to raise_error(described_class::Error, /latest committed regular/)
    manifest["history_through_work_date"] = period.end_date.iso8601
    manifest["issued_entries"].first["source_time_entry_version"] = 2
    allow(client).to receive(:payroll_cockpit_history_entries).and_return(
      "time_entries" => [ { "id" => "41", "source_user_uuid" => uuid, "version" => 2, "hours" => 6.1 },
                          { "id" => "99", "source_user_uuid" => uuid, "version" => 3, "hours" => 2 } ],
      "pagination" => { "current_page" => 1, "total_pages" => 1, "total_count" => 2, "truncated" => false })
    rollout = described_class.new(manifest: manifest, actor: actor)
    digest = Digest::SHA256.hexdigest(JSON.generate(manifest))
    expect { rollout.apply!(accepted_manifest_sha256: digest, release_owner: "Approved test owner") }
      .to raise_error(described_class::Error, /without a verified disposition/)
    expect(item.check_events.deliveries.count).to eq(0)
    manifest["reviewed_unpaid_entries"] = [ { "source_time_entry_id" => "99", "source_user_uuid" => uuid, "source_time_entry_version" => 3 } ]
    rollout = described_class.new(manifest: manifest, actor: actor)
    digest = Digest::SHA256.hexdigest(JSON.generate(manifest))
    rollout.apply!(accepted_manifest_sha256: digest, release_owner: "Approved test owner")
    expect(AireVerifiedHistoryRolloutReceipt.last.coverage_verified).to be(true)
  end

  context "when separate issued checks cover parts of one historical source entry" do
    let(:second_period) do
      create(:pay_period, :committed, company: company, start_date: Date.new(2026, 8, 16),
        end_date: Date.new(2026, 8, 31), pay_date: Date.new(2026, 9, 15))
    end
    let(:second_item) do
      create(:payroll_item, :with_check, company: company, pay_period: second_period, employee: employee,
        hours_worked: 3.05, overtime_hours: 0, pay_rate: 10, gross_pay: 30.5, net_pay: 25)
    end
    let(:already_issued) { true }
    let(:inventory_entry) do
      { "id" => "41", "source_user_uuid" => uuid, "version" => 2, "hours" => 6.1,
        "regular_hours" => 6.1, "overtime_hours" => 0 }
    end

    before do
      source.update!(expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
        source_protocol_version: "2.0", identity_verified_at: Time.current)
      source.update_column(:historical_reconciliation_required, true)
      item.update!(hours_worked: 3.05, gross_pay: 30.5, net_pay: 25)
      manifest["source_instance_id"] = source.expected_source_instance_id
      manifest["history_through_work_date"] = second_period.end_date.iso8601
      manifest["delivered_checks"].first.merge!("regular_hours" => "3.05", "net_pay" => "25.00")
      manifest["delivered_checks"] << manifest["delivered_checks"].first.merge(
        "payroll_item_id" => second_item.id, "pay_period_id" => second_period.id, "check_number" => second_item.check_number)
      manifest["issued_entries"].first.merge!("source_time_entry_version" => 2, "regular_hours" => "3.05")
      manifest["issued_entries"] << manifest["issued_entries"].first.merge("payroll_item_id" => second_item.id)
      (already_issued ? [ item, second_item ] : []).each_with_index do |paid_item, index|
        TimeTrackingManualAllocation.create!(company: company, time_tracking_source: source,
          pay_period: paid_item.pay_period, payroll_item: paid_item, employee: employee, created_by: actor,
          source_user_uuid: uuid, source_time_entry_id: "41", source_time_entry_version: 2,
          original_work_date: Date.new(2026, 8, 14), regular_hours: 3.05, overtime_hours: 0,
          reconciliation_note: "Verified partial historical hours on this delivered check", status: "issued",
          remote_allocation_id: (501 + index).to_s)
      end
      allow(client).to receive(:payroll_cockpit_history_entries).and_return(
        "time_entries" => [ inventory_entry ],
        "pagination" => { "current_page" => 1, "total_pages" => 1, "total_count" => 1, "truncated" => false })
    end

    def apply_accepted_history
      digest = Digest::SHA256.hexdigest(JSON.generate(manifest))
      described_class.new(manifest: manifest, actor: actor).apply!(
        accepted_manifest_sha256: digest, release_owner: "Approved test owner")
    end

    it "approves only the aggregate of both partial checks without creating duplicate allocations" do
      expect(described_class.new(manifest: manifest, actor: actor).preview!).to include(history_coverage_verified: true)
      expect { apply_accepted_history }.not_to change(TimeTrackingManualAllocation, :count)
      expect(source.historical_reconciliation_complete?).to be(true)
      expect(AireVerifiedHistoryRolloutReceipt.last.coverage_verified).to be(true)
      expect(client).not_to have_received(:commit_payroll_manual_allocation)
    end

    context "when the partial check evidence has not been linked yet" do
      let(:already_issued) { false }

      it "creates both partial allocations and certifies their complete combined coverage" do
        rollout = described_class.new(manifest: manifest, actor: actor)
        allow(rollout).to receive(:pace_source_entry!)
        digest = Digest::SHA256.hexdigest(JSON.generate(manifest))
        expect { rollout.apply!(accepted_manifest_sha256: digest, release_owner: "Approved test owner") }
          .to change(TimeTrackingManualAllocation, :count).by(2)
        expect(TimeTrackingManualAllocation.where(status: "issued").sum(:regular_hours)).to eq(6.1)
        expect(source.historical_reconciliation_complete?).to be(true)
      end
    end

    it "holds incomplete evidence even though its source identity and version are covered" do
      manifest["issued_entries"].pop
      expect(described_class.new(manifest: manifest, actor: actor).preview!).to include(history_coverage_verified: false)
      expect { apply_accepted_history }.to raise_error(described_class::Error, /without a verified disposition/)
      expect(source.historical_reconciliation_complete?).to be(false)
      expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
      expect(item.check_events.deliveries.count).to eq(0)
    end

    it "holds an equal total with the wrong inventoried REG and OT split" do
      inventory_entry.merge!("regular_hours" => 5.1, "overtime_hours" => 1)
      expect { apply_accepted_history }.to raise_error(described_class::Error, /without a verified disposition/)
      expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    end

    it "requires complete finite total hours even if the optional split is unavailable" do
      inventory_entry.delete("regular_hours")
      inventory_entry.delete("overtime_hours")
      [ nil, "NaN", "Infinity", -1, 6.09, 6.2 ].each do |invalid_hours|
        inventory_entry["hours"] = invalid_hours
        expect { apply_accepted_history }.to raise_error(described_class::Error, /without a verified disposition/)
      end
      inventory_entry["hours"] = 6.1
      apply_accepted_history
      expect(source.historical_reconciliation_complete?).to be(true)
    end

    it "holds completion when total hours drift in the fresh final source read" do
      initial = { "time_entries" => [ inventory_entry ],
        "pagination" => { "current_page" => 1, "total_pages" => 1, "total_count" => 1, "truncated" => false } }
      changed = initial.deep_dup
      changed["time_entries"].first.merge!("hours" => 6.2, "regular_hours" => 6.2)
      allow(client).to receive(:payroll_cockpit_history_entries).and_return(initial, changed)
      expect { apply_accepted_history }.to raise_error(described_class::Error, /without a verified disposition/)
      expect(source.historical_reconciliation_complete?).to be(false)
      expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
      expect(TimeTrackingManualAllocation.where(status: "issued").count).to eq(2)
    end

    it "rejects conflicting versions or dates on an existing partial allocation" do
      row = manifest["issued_entries"].last
      row["source_time_entry_version"] = 3
      expect { apply_accepted_history }.to raise_error(described_class::Error, /conflicting payment evidence/)
      row["source_time_entry_version"] = 2
      row["original_work_date"] = "2026-08-13"
      expect { apply_accepted_history }.to raise_error(described_class::Error, /conflicting payment evidence/)
      expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    end

    it "rejects issued local hours changed after preflight rather than certifying the old manifest" do
      rollout = described_class.new(manifest: manifest, actor: actor)
      allow(rollout).to receive(:apply_exact_entries!).and_wrap_original do |original|
        original.call
        TimeTrackingManualAllocation.find_by!(payroll_item: second_item).update!(regular_hours: 3)
      end
      digest = Digest::SHA256.hexdigest(JSON.generate(manifest))
      expect { rollout.apply!(accepted_manifest_sha256: digest, release_owner: "Approved test owner") }
        .to raise_error(described_class::Error, /Not all verified AIRE entries have issued payment evidence/)
      expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
      expect(source.historical_reconciliation_complete?).to be(false)
    end

    it "rejects duplicate evidence for the same payroll item and source entry" do
      manifest["issued_entries"] << manifest["issued_entries"].first.deep_dup
      expect { apply_accepted_history }.to raise_error(described_class::Error, /source entries contain duplicates/)
    end
  end

  it "rejects a historical inventory that omits rows from its advertised total" do
    manifest["history_through_work_date"] = period.end_date.iso8601
    allow(client).to receive(:payroll_cockpit_history_entries).and_return(
      "time_entries" => [ { "id" => "41", "source_user_uuid" => uuid, "version" => 2, "hours" => 6.1 } ],
      "pagination" => { "current_page" => 1, "total_pages" => 1, "total_count" => 2, "truncated" => false })
    expect { described_class.new(manifest: manifest, actor: actor).preview! }
      .to raise_error(described_class::Error, /incomplete historical source inventory/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
  end

  it "keeps completion closed when the fresh final inventory gains an unreviewed entry" do
    source.update!(expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "2.0", identity_verified_at: Time.current)
    source.update_column(:historical_reconciliation_required, true)
    manifest["source_instance_id"] = source.expected_source_instance_id
    manifest["history_through_work_date"] = period.end_date.iso8601
    manifest["issued_entries"].first["source_time_entry_version"] = 2
    initial = { "time_entries" => [ { "id" => "41", "source_user_uuid" => uuid, "version" => 2, "hours" => 6.1 } ],
      "pagination" => { "current_page" => 1, "total_pages" => 1, "total_count" => 1, "truncated" => false } }
    changed = initial.deep_dup
    changed["time_entries"] << { "id" => "99", "source_user_uuid" => uuid, "version" => 0, "hours" => 2 }
    changed["pagination"]["total_count"] = 2
    allow(client).to receive(:payroll_cockpit_history_entries).and_return(initial, changed)
    digest = Digest::SHA256.hexdigest(JSON.generate(manifest))

    expect { described_class.new(manifest: manifest, actor: actor).apply!(
      accepted_manifest_sha256: digest, release_owner: "Approved test owner") }
      .to raise_error(described_class::Error, /without a verified disposition/)
    expect(AireVerifiedHistoryRolloutReceipt.count).to eq(0)
    expect(source.historical_reconciliation_complete?).to be(false)
    # Remote writes have already happened. Preserve their idempotent command IDs.
    expect(TimeTrackingManualAllocation.find_by!(source_time_entry_id: "41").status).to eq("issued")
  end

  it "lets an assigned accountant approve bindings and complete history without broader configuration authority" do
    home = create(:company, organization: company.organization)
    actor.update!(company: home, role: "accountant")
    create(:company_assignment, user: actor, company: company)
    expect(StaffRolePolicy.allowed?(actor, :manage_client_configuration)).to be(false)
    source.update!(expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
      source_protocol_version: "2.0", identity_verified_at: Time.current)
    source.update_column(:historical_reconciliation_required, true)
    mapping = TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee,
      source_user_id: "91", source_user_uuid: nil)
    import = create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source)
    allocation = TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source, time_tracking_import: import,
      pay_period: period, payroll_item: item, employee: employee, source_user_id: "91", source_user_uuid: nil,
      source_time_entry_id: "41", original_work_date: Date.new(2026, 8, 14), line_key: "category:1", source_kind: "current",
      total_hours: 6.1, regular_hours: 6.1, overtime_hours: 0)
    old = AirePayrollEntryAcknowledgement.record_for_import!(time_tracking_import: import, status: "committed", occurred_at: Time.current).first
    manifest["source_instance_id"] = source.expected_source_instance_id
    manifest["history_through_work_date"] = period.end_date.iso8601
    manifest["issued_entries"] = []
    manifest["finalized_batch_entries"] = [ { "payroll_item_id" => item.id, "source_time_entry_id" => "41", "source_line_key" => "category:1",
      "source_user_uuid" => uuid, "source_time_entry_version" => 2, "regular_hours" => "6.10", "overtime_hours" => "0.00" } ]
    manifest["legacy_identity_bindings"] = [ { "allocation_id" => allocation.id, "mapping_id" => mapping.id,
      "source_user_uuid" => uuid, "source_time_entry_id" => "41", "source_time_entry_version" => 2,
      "source_line_key" => "category:1", "original_work_date" => "2026-08-14", "external_batch_id" => import.external_batch_id,
      "batch_checksum" => import.external_batch_checksum, "source_instance_id" => source.expected_source_instance_id, "source_total_hours" => "6.10" } ]
    allow(client).to receive(:payroll_cockpit_time_entry).and_return("time_entry" => { "id" => "41", "version" => 2,
      "work_date" => "2026-08-14", "hours" => 6.1, "employee" => { "id" => "91", "payroll_integration_id" => uuid, "name" => employee.full_name } })
    allow(client).to receive(:payroll_cockpit_history_entries).and_return("time_entries" => [ { "id" => "41", "version" => 2, "source_user_uuid" => uuid, "hours" => 6.1 } ],
      "pagination" => { "current_page" => 1, "total_pages" => 1, "total_count" => 1, "truncated" => false })
    allow(client).to receive(:record_payroll_entry_processing_event).and_return("ok" => true)
    digest = Digest::SHA256.hexdigest(JSON.generate(manifest))
    described_class.new(manifest: manifest, actor: actor).apply!(accepted_manifest_sha256: digest, release_owner: "Approved test owner")
    expect(allocation.reload.source_user_uuid).to be_nil
    expect(old.reload.source_user_uuid).to be_nil
    expect(item.aire_payroll_entry_acknowledgements.find_by!(status: "payment_issued").source_user_uuid).to eq(uuid)
    expect(source.historical_reconciliation_complete?).to be(true)
    expect { described_class.new(manifest: manifest, actor: actor).apply!(accepted_manifest_sha256: digest, release_owner: "Approved test owner") }
      .not_to change(TimeTrackingLegacyIdentityBinding, :count)
  end
end
