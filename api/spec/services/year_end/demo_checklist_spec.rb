# frozen_string_literal: true

require "rails_helper"

RSpec.describe YearEnd::Checklist, "for a demo company" do
  before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

  let(:organization) { create(:organization) }
  let(:company) { create_demo_company(organization: organization, ein: "98-7654321") }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department, ssn_encrypted: "900-01-0001") }
  let(:admin) { create(:user, company: company, organization: organization, role: "admin") }

  before do
    create_committed_demo_pay_period(company: company, pay_date: Date.new(2026, 3, 6), employee: employee)
    %w[w2_gu form_1099].zip(%w[cornerstone no_filing]).each do |filing_type, party|
      PayrollFilingResponsibilityRecorder.new(company: company, actor: admin, tax_year: 2026, filing_types: [ filing_type ],
        responsible_party: party, imported_payroll_inclusion: "included", prior_provider_through: nil).call
    end
    fingerprint = W2FilingInputsFingerprint.new(company: company, year: 2026).call
    W2FilingReadiness.create!(company: company, year: 2026, status: "filing_ready", preflight_fingerprint: fingerprint,
      ready_fingerprint: fingerprint, marked_ready_at: Time.current, marked_ready_by: admin)
  end

  def checklist
    described_class.new(company: company.reload, year: 2026, user: admin).call
  end

  it "prepares final copies like a live client but never offers the e-file" do
    result = checklist
    print_step = result[:steps].find { |entry| entry[:key] == "print_and_file" }

    expect(result.dig(:company, :test_workspace)).to be(false)
    expect(print_step.dig(:data, :final)).to be(true)
    employee_copies, copy_1, efile, totals = print_step.dig(:data, :documents)
    expect(employee_copies).to include(draft: false, available: true)
    expect(copy_1).to include(draft: false, available: true, unavailable_reason: nil)
    expect(totals).to include(draft: false, available: true, unavailable_reason: nil)
    expect(efile).to include(available: false, unavailable_reason: Company::DEMO_UNAVAILABLE_MESSAGE)
  end

  it "runs e-file preflight and collapses fictional 9xx SSNs into one labeled expected error without blocking sign-off" do
    result = checklist
    people_step = result[:steps].find { |entry| entry[:key] == "people" }
    codes = result[:steps].flat_map { |entry| Array(entry[:issues]) }.map { |issue| issue[:code] }

    expect(result.dig(:company, :demo)).to be(true)
    expect(codes).to include("DEMO_RESERVED_SSN_EXPECTED")
    expect(codes).not_to include("EMPLOYEE_EFILE_INVALID")
    expect(people_step[:status]).to eq("done")
    expect(people_step[:issues].sole).to include(code: "DEMO_RESERVED_SSN_EXPECTED", expected_for_demo: true)
    expect(result[:status]).to eq("ready")
    expect(result[:issue_count]).to eq(0)
    expect(described_class.new(company: company.reload, year: 2026, user: admin).w2_mark_ready_blockers).to be_empty
    expect(YearEnd::EfileCheck.read_many([ company.id ], 2026)[company.id]).to be_present
  end

  it "still flags real paper W-2 and non-9xx EFW2 errors as blockers" do
    employee.update_columns(address_line1: nil)

    result = checklist
    blockers = described_class.new(company: company.reload, year: 2026, user: admin).w2_mark_ready_blockers
    codes = result[:steps].flat_map { |entry| Array(entry[:issues]) }.map { |issue| issue[:code] }
    expect(codes).to include("EMPLOYEE_DETAILS_MISSING", "DEMO_RESERVED_SSN_EXPECTED")
    expect(blockers.map { |entry| entry[:code] }).to include("EMPLOYEE_DETAILS_MISSING")
    expect(blockers.map { |entry| entry[:code] }).not_to include("DEMO_RESERVED_SSN_EXPECTED")
  end

  it "keeps the official EFW2 validator refusing the reserved area" do
    report = W2GuAggregator.new(company, 2026).generate
    problems = Efw2W2GuGenerator.new(company: company, year: 2026, submitter: nil, report: report).structured_problems
    expect(problems.map { |problem| problem[:code] }).to include(:ssn_invalid)
  end

  it "labels a fictional reserved demo EIN (07-...) as expected without blocking sign-off or loosening EFW2" do
    company.update!(ein: "07-2026101")
    fingerprint = W2FilingInputsFingerprint.new(company: company.reload, year: 2026).call
    W2FilingReadiness.where(company: company, year: 2026).update_all(preflight_fingerprint: fingerprint, ready_fingerprint: fingerprint)

    result = checklist
    employer_step = result[:steps].find { |entry| entry[:key] == "employer" }
    expect(employer_step[:status]).to eq("done")
    expect(employer_step[:issues].sole).to include(code: "DEMO_RESERVED_EIN_EXPECTED", expected_for_demo: true, field: "ein")
    expect(result[:status]).to eq("ready")
    expect(result[:issue_count]).to eq(0)
    expect(described_class.new(company: company.reload, year: 2026, user: admin).w2_mark_ready_blockers).to be_empty

    report = W2GuAggregator.new(company, 2026).generate
    problems = Efw2W2GuGenerator.new(company: company, year: 2026, submitter: nil, report: report).structured_problems
    expect(problems.map { |problem| problem[:code] }).to include(:ein_invalid)
  end
end
