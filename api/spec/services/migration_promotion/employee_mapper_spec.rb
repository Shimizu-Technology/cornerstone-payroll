# frozen_string_literal: true

require "rails_helper"

RSpec.describe MigrationPromotion::EmployeeMapper do
  let(:organization) { create(:organization) }
  let(:target_company) { create(:company, organization: organization) }
  let(:source_batch) do
    create(
      :historical_import_batch,
      company: target_company,
      status: "locked",
      importer_version: "legacy-test-importer"
    )
  end
  let(:rehearsal) do
    create(
      :company,
      organization: organization,
      payroll_environment: "migration_rehearsal",
      test_workspace_purpose: "migration_rehearsal",
      migration_source_company: target_company,
      migration_source_batch: source_batch,
      migration_rehearsal_status: "ready"
    )
  end
  let(:copied_batch) do
    create(
      :historical_import_batch,
      company: rehearsal,
      bundle_digest: source_batch.bundle_digest,
      status: "locked",
      importer_version: "legacy-test-importer"
    )
  end

  it "recovers employee identity from matching historical worker keys for rehearsals created before lineage existed" do
    target_employee = create(:employee, company: target_company)
    rehearsal_employee = create(:employee, company: rehearsal)
    create(
      :historical_worker,
      historical_import_batch: source_batch,
      company: target_company,
      employee: target_employee,
      external_key: "worker-42",
      mapping_status: "exact_match"
    )
    create(
      :historical_worker,
      historical_import_batch: copied_batch,
      company: rehearsal,
      employee: rehearsal_employee,
      external_key: "worker-42",
      mapping_status: "exact_match"
    )

    result = described_class.new(rehearsal: rehearsal).call

    expect(result).to be_ready
    expect(result.map).to eq(rehearsal_employee.id => target_employee)
    expect(result.new_employees).to be_empty
  end

  it "blocks instead of guessing when two target employees share the rehearsal employee's SSN" do
    rehearsal_employee = create(:employee, company: rehearsal, ssn_encrypted: "900-70-1234")
    create(:employee, company: target_company, ssn_encrypted: "900-70-1234")
    create(:employee, company: target_company, ssn_encrypted: "900-70-1234")

    result = described_class.new(rehearsal: rehearsal).call

    expect(result).not_to be_ready
    expect(result.blockers.join).to include("matches multiple employees")
  end

  it "prefers the active operational employee and preserves an inactive historical identity" do
    active_target = create(:employee, company: target_company, status: "active", ssn_encrypted: "900-70-4567")
    historical_target = create(:employee, company: target_company, status: "inactive", ssn_encrypted: "900-70-4567")
    rehearsal_employee = create(:employee, company: rehearsal, status: "active", ssn_encrypted: "900-70-4567")
    create(
      :historical_worker,
      historical_import_batch: source_batch,
      company: target_company,
      employee: historical_target,
      external_key: "archived-worker-7",
      mapping_status: "exact_match"
    )

    result = described_class.new(rehearsal: rehearsal).call

    expect(result).to be_ready
    expect(result.map).to eq(rehearsal_employee.id => active_target)
    expect(result.blockers).to be_empty
  end

  it "blocks when an active clean-client employee is missing from the rehearsal" do
    create(:employee, company: target_company, status: "active")

    result = described_class.new(rehearsal: rehearsal).call

    expect(result).not_to be_ready
    expect(result.blockers).to include("1 clean-client employee is missing from the rehearsal")
  end
end
