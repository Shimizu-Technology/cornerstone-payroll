# frozen_string_literal: true
require "rails_helper"

RSpec.describe TimeTracking::LegacyIdentityBindingService do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", expected_source_instance_id: SecureRandom.uuid,
    source_protocol: "shimizu_time_payroll", source_protocol_version: "2.0", identity_verified_at: Time.current) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:period) { create(:pay_period, :committed, company: company) }
  let(:item) { create(:payroll_item, company: company, employee: employee, pay_period: period) }
  let(:import) { create(:time_tracking_import, :finalized_aire_batch, time_tracking_source: source, pay_period: period) }
  let(:allocation) { TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source, time_tracking_import: import,
    pay_period: period, payroll_item: item, employee: employee, source_user_id: "91", source_user_uuid: nil,
    source_time_entry_id: "41", original_work_date: period.start_date, line_key: "category:1", source_kind: "current",
    total_hours: 4, regular_hours: 4, overtime_hours: 0) }
  let(:mapping) { TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source, employee: employee, source_user_id: "91", source_user_uuid: nil) }
  let(:uuid) { SecureRandom.uuid }
  let(:identity) { { "employee_id" => employee.id, "employee_name" => employee.full_name, "source_user_id" => "91", "source_user_uuid" => uuid } }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:digest) { "a" * 64 }
  let(:evidence) { { "allocation_id" => allocation.id, "mapping_id" => mapping.id, "source_user_uuid" => uuid,
    "source_time_entry_id" => "41", "source_time_entry_version" => 2, "source_line_key" => "category:1",
    "original_work_date" => period.start_date.iso8601, "external_batch_id" => import.external_batch_id,
    "batch_checksum" => import.external_batch_checksum, "source_instance_id" => source.expected_source_instance_id,
    "source_total_hours" => "4.00" } }
  let(:remote) { { "time_entry" => { "id" => "41", "version" => 2, "work_date" => period.start_date.iso8601, "hours" => 4,
    "employee" => { "id" => "91", "payroll_integration_id" => uuid, "name" => employee.full_name } } } }
  let(:service) { described_class.new(source: source, actor: actor, manifest_sha256: digest, client: client) }
  before { allow(client).to receive(:payroll_cockpit_time_entry).with(entry_id: "41").and_return(remote) }

  def bind
    service.apply!(binding: service.verify!(evidence: evidence, identity: identity), accepted_manifest_sha256: digest, release_owner: "Approved test owner")
  end

  it "preserves original allocation and prior null-UUID acknowledgement while new evidence uses the approved binding" do
    allocation
    old = AirePayrollEntryAcknowledgement.record_for_import!(time_tracking_import: import, status: "committed", occurred_at: Time.current).first
    expect(old.source_user_uuid).to be_nil
    binding = bind
    expect(binding.source_user_uuid).to eq(uuid)
    expect(allocation.reload.source_user_uuid).to be_nil
    expect(old.reload.source_user_uuid).to be_nil
    fresh = AirePayrollEntryAcknowledgement.record_for_import!(time_tracking_import: import, status: "payment_issued", occurred_at: Time.current).first
    expect(fresh.source_user_uuid).to eq(uuid)
    expect { bind }.not_to change(TimeTrackingLegacyIdentityBinding, :count)
    expect { ApplicationRecord.transaction(requires_new: true) { TimeTrackingLegacyIdentityBinding.where(id: binding.id).update_all(source_user_uuid: SecureRandom.uuid) } }
      .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    expect { ApplicationRecord.transaction(requires_new: true) { TimeTrackingEntryAllocation.where(id: allocation.id).update_all(employee_id: create(:employee).id) } }
      .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
  end

  it "requires accepted approval even in a local rehearsal" do
    pending = service.verify!(evidence: evidence, identity: identity)
    expect { service.apply!(binding: pending, accepted_manifest_sha256: "b" * 64, release_owner: "test") }
      .to raise_error(described_class::Error, /accepted manifest/)
    expect { pending.save! }.to raise_error(ActiveRecord::RecordInvalid, /accepted rollout/)
    expect(TimeTrackingLegacyIdentityBinding.count).to eq(0)
  end

  it "rejects wrong company, numeric mapping owner, batch checksum, and current source-version drift" do
    expect { service.verify!(evidence: evidence.merge("allocation_id" => -1), identity: identity) }.to raise_error(described_class::Error)
    expect { service.verify!(evidence: evidence.merge("batch_checksum" => "b" * 64), identity: identity) }.to raise_error(described_class::Error, /batch evidence/)
    remote["time_entry"]["version"] = 3
    expect { service.verify!(evidence: evidence, identity: identity) }.to raise_error(described_class::Error, /version/)
    remote["time_entry"]["version"] = 2
    mapping.update!(employee: create(:employee, company: company, department: employee.department))
    expect { service.verify!(evidence: evidence, identity: identity) }.to raise_error(described_class::Error, /owner/)
    expect(TimeTrackingLegacyIdentityBinding.count).to eq(0)
  end

  it "rejects a different source person or altered accepted evidence on replay" do
    remote["time_entry"]["employee"]["payroll_integration_id"] = SecureRandom.uuid
    expect { service.verify!(evidence: evidence, identity: identity) }.to raise_error(described_class::Error, /identity/)
    remote["time_entry"]["employee"]["payroll_integration_id"] = uuid
    bind
    expect { service.verify!(evidence: evidence.merge("source_time_entry_version" => 9), identity: identity) }
      .to raise_error(described_class::Error, /replay differs/)
  end
  it "rejects direct database insertion for another company or a different immutable batch" do
    candidate = service.verify!(evidence: evidence, identity: identity)
    raw = candidate.attributes.except("id").merge("release_owner" => "Approved test owner", "created_at" => Time.current)
    other_company = create(:company)
    expect { ApplicationRecord.transaction(requires_new: true) {
      TimeTrackingLegacyIdentityBinding.insert_all!([ raw.merge("company_id" => other_company.id) ])
    } }.to raise_error(ActiveRecord::StatementInvalid, /tenant, source, owner, or batch/)
    expect { ApplicationRecord.transaction(requires_new: true) {
      TimeTrackingLegacyIdentityBinding.insert_all!([ raw.merge("batch_checksum" => "b" * 64) ])
    } }.to raise_error(ActiveRecord::StatementInvalid, /tenant, source, owner, or batch/)
    expect(TimeTrackingLegacyIdentityBinding.count).to eq(0)
  end

end
