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

  it "does not flag the fictional reserved-area SSNs or mention practice, test or demo status" do
    result = checklist
    codes = result[:steps].flat_map { |entry| Array(entry[:issues]) }.map { |issue| issue[:code] }

    expect(codes).not_to include("EMPLOYEE_EFILE_INVALID")
    expect(result.to_json).not_to match(/practice copy|test workspace|demo/i)
  end

  it "runs no e-file preflight and writes no e-file check, but keeps the paper W-2 checks" do
    expect(YearEnd::EfileCheck).not_to receive(:record)
    expect(Efw2W2GuGenerator).not_to receive(:new)
    employee.update_columns(address_line1: nil)

    result = checklist
    described_class.new(company: company.reload, year: 2026, user: admin).w2_mark_ready_blockers
    codes = result[:steps].flat_map { |entry| Array(entry[:issues]) }.map { |issue| issue[:code] }
    expect(codes).to include("EMPLOYEE_DETAILS_MISSING")
    expect(codes).not_to include("EMPLOYEE_EFILE_INVALID", "EMPLOYER_EFILE_INVALID")
    expect(YearEnd::EfileCheck.read_many([ company.id ], 2026)).to be_empty
  end

  it "keeps the official EFW2 validator refusing the reserved area" do
    report = W2GuAggregator.new(company, 2026).generate
    problems = Efw2W2GuGenerator.new(company: company, year: 2026, submitter: nil, report: report).structured_problems
    expect(problems.map { |problem| problem[:code] }).to include(:ssn_invalid)
  end
end
