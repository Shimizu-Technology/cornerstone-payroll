# frozen_string_literal: true

require "rails_helper"

RSpec.describe YearEnd::Checklist do
  let(:company) { create(:company, ein: "98-7654321") }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let(:accountant) { create(:user, company: company, organization: company.organization, role: "accountant") }

  def pay(pay_date, worker: employee, **amounts)
    period = PayPeriod.find_by(company: company, pay_date: pay_date) ||
      create(:pay_period, :committed, company: company, start_date: pay_date - 17.days, end_date: pay_date - 3.days, pay_date: pay_date)
    create(:payroll_item, {
      company: company, employee: worker, pay_period: period,
      gross_pay: 2_000, net_pay: 1_600, withholding_tax: 150,
      social_security_tax: 124, employer_social_security_tax: 124,
      medicare_tax: 29, employer_medicare_tax: 29,
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000
    }.merge(amounts))
  end

  def decide(w2: "cornerstone", form_1099: "no_filing", prior_provider_through: nil)
    { "w2_gu" => [ w2, prior_provider_through ], "form_1099" => [ form_1099, nil ] }.each do |filing_type, (party, through)|
      PayrollFilingResponsibilityRecorder.new(
        company: company, actor: accountant, tax_year: 2026, filing_types: [ filing_type ],
        responsible_party: party, imported_payroll_inclusion: "included", prior_provider_through: through
      ).call
    end
  end

  def checklist
    described_class.new(company: company.reload, year: 2026, user: accountant).call
  end

  def step(result, key)
    result[:steps].find { |entry| entry[:key] == key }
  end

  it "requires the filing decision before anything else" do
    pay(Date.new(2026, 3, 6))

    result = checklist

    expect(result[:status]).to eq("needs_action")
    expect(result[:next_step]).to eq("filing_decision")
    expect(step(result, "filing_decision")[:issues].map { |issue| issue[:code] }).to eq(%w[W2_FILER_NOT_CHOSEN FORM_1099_FILER_NOT_CHOSEN])
    expect(result[:steps].drop(1).map { |entry| entry[:status] }).to all(eq("waiting"))
    expect(described_class.new(company: company, year: 2026).w2_mark_ready_blockers.map { |issue| issue[:code] })
      .to include("W2_FILER_NOT_CHOSEN")
  end

  it "takes a record that files no forms off the to-do list without deleting anything" do
    pay(Date.new(2026, 6, 5))
    decide(w2: "no_filing", form_1099: "no_filing")

    result = checklist

    expect(result[:status]).to eq("not_filing")
    expect(result[:issue_count]).to eq(0)
    expect(result[:steps].drop(1).map { |entry| entry[:status] }).to all(eq("not_needed"))
    expect(PayPeriod.where(company: company).count).to eq(1)
    expect(PayrollFilingResponsibility.where(company: company, tax_year: 2026).count).to eq(2)
  end

  it "lists missing employer, SSN and address details, and clears each one once fixed" do
    company.update_columns(ein: nil, phone: nil)
    worker = create(:employee, company: company, department: department)
    worker.update_columns(ssn_encrypted: nil, city: nil)
    pay(Date.new(2026, 3, 6), worker: worker)
    decide

    result = checklist

    expect(step(result, "employer")[:issues].map { |issue| issue[:code] }).to eq(%w[EMPLOYER_EIN_MISSING EMPLOYER_PHONE_MISSING])
    people = step(result, "people")
    expect(people[:issues]).to contain_exactly(a_hash_including(code: "EMPLOYEE_DETAILS_MISSING", employee_id: worker.id))
    expect(people.dig(:data, :employees, 0)).to include(employee_id: worker.id, missing_fields: %w[ssn address])
    expect(people.to_json).not_to include("ssn_encrypted")

    company.update!(ein: "98-7654321", phone: "671-555-0100")
    worker.update_columns(city: "Tamuning")
    result = checklist
    expect(step(result, "employer")[:status]).to eq("done")
    expect(step(result, "people").dig(:data, :employees, 0, :missing_fields)).to eq(%w[ssn])

    worker.update_columns(ssn_encrypted: "900-70-1234")
    expect(step(checklist, "people")[:status]).to eq("done")
  end

  it "blocks on a fixable judgment warning and needs an acknowledgement for a judgment call" do
    pay(Date.new(2026, 4, 3), reported_tips: 200, gross_pay: 2_200, cash_tips_reported: nil,
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 200, medicare_taxable_wages: 2_200,
      social_security_tax: 136.40, employer_social_security_tax: 136.40, medicare_tax: 31.90, employer_medicare_tax: 31.90)
    decide

    warnings = step(checklist, "review_warnings")
    codes = warnings[:issues].map { |issue| [ issue[:code], issue[:warning_code] ] }
    expect(codes).to contain_exactly(
      [ "JUDGMENT_WARNING_BLOCKING", "tipped_occupation_code_missing" ],
      [ "JUDGMENT_WARNING_UNREVIEWED", "tip_classification_unreviewed" ]
    )
    tips = warnings.dig(:data, :warnings).find { |warning| warning[:code] == "tip_classification_unreviewed" }
    expect(tips).to include(kind: "acknowledge", status: "needs_review")

    create(:employee_tipped_occupation, employee: employee)
    YearEnd::AcknowledgementRecorder.new(
      company: company, actor: accountant, tax_year: 2026, warning_code: "tip_classification_unreviewed",
      warning_digest: tips[:digest], note: "Checked the tip log; all tips were cash tips."
    ).call

    warnings = step(checklist, "review_warnings")
    expect(warnings[:status]).to eq("done")
    expect(warnings.dig(:data, :warnings, 0)).to include(status: "reviewed", acknowledgement: a_hash_including(note: "Checked the tip log; all tips were cash tips."))

    pay(Date.new(2026, 5, 1), reported_tips: 50, gross_pay: 2_050, cash_tips_reported: nil,
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 50, medicare_taxable_wages: 2_050)
    warnings = step(checklist, "review_warnings")
    expect(warnings[:issues]).to contain_exactly(a_hash_including(code: "JUDGMENT_WARNING_UNREVIEWED", message: a_string_including("data changed")))
  end

  it "blocks ready when opening balances cover a period the prior provider files" do
    create_historical_filing_source(
      company: company, employee: employee, pay_date: Date.new(2026, 6, 30),
      gross_pay: 12_000, federal_income_tax: 900, social_security_tax: 744, medicare_tax: 174,
      employer_social_security_tax: 744, employer_medicare_tax: 174,
      period_type: "opening_summary", period_start: Date.new(2026, 1, 1), period_end: Date.new(2026, 6, 30)
    )
    pay(Date.new(2026, 8, 7))
    decide(prior_provider_through: Date.new(2026, 3, 31))

    result = checklist

    overlap = step(result, "prior_provider")
    expect(overlap[:status]).to eq("action_needed")
    expect(overlap[:issues]).to contain_exactly(a_hash_including(code: "PRIOR_PROVIDER_OVERLAP", source: "opening_balances"))
    expect(overlap[:issues].first[:message]).to include("Jan 1, 2026", "Mar 31, 2026")
    expect(described_class.new(company: company, year: 2026).w2_mark_ready_blockers.map { |issue| issue[:code] })
      .to include("PRIOR_PROVIDER_OVERLAP")

    decide(prior_provider_through: nil)
    expect(step(checklist, "prior_provider")[:status]).to eq("done")
  end

  it "ignores contractor-only payroll in the prior provider's W-2 period" do
    contractor = create(:employee, :contractor, company: company, department: department)
    pay(Date.new(2026, 2, 6), worker: contractor, employment_type: "contractor", social_security_tax: 0, medicare_tax: 0,
      employer_social_security_tax: 0, employer_medicare_tax: 0, social_security_taxable_wages: nil, social_security_taxable_tips: nil,
      medicare_taxable_wages: nil, withholding_tax: 0)
    pay(Date.new(2026, 8, 7))
    decide(prior_provider_through: Date.new(2026, 3, 31))

    expect(step(checklist, "prior_provider")).to include(status: "done", issues: [])

    pay(Date.new(2026, 3, 6))
    expect(step(checklist, "prior_provider")[:issues]).to contain_exactly(a_hash_including(code: "PRIOR_PROVIDER_OVERLAP", source: "cornerstone_payroll"))
  end

  it "is ready once every step is done and the W-2s are marked ready on the current numbers" do
    pay(Date.new(2026, 3, 6))
    decide

    result = checklist
    expect(result[:next_step]).to eq("mark_ready")
    expect(step(result, "mark_ready").dig(:data, :can_mark_ready)).to be(true)

    fingerprint = W2FilingInputsFingerprint.new(company: company, year: 2026).call
    W2FilingReadiness.create!(company: company, year: 2026, status: "filing_ready", preflight_fingerprint: fingerprint,
      ready_fingerprint: fingerprint, marked_ready_at: Time.current, marked_ready_by: accountant)

    expect(checklist).to include(status: "ready", issue_count: 0)

    pay(Date.new(2026, 4, 3))
    result = checklist
    expect(result[:status]).to eq("needs_action")
    expect(step(result, "mark_ready")[:issues].first[:message]).to include("changed after the W-2s were marked ready")
  end

  it "reuses the W-2GU report for the readiness fingerprint" do
    pay(Date.new(2026, 3, 6))
    decide
    fingerprint = W2FilingInputsFingerprint.new(company: company, year: 2026).call
    W2FilingReadiness.create!(company: company, year: 2026, status: "filing_ready", preflight_fingerprint: fingerprint,
      ready_fingerprint: fingerprint, marked_ready_at: Time.current)

    expect(W2GuAggregator).to receive(:new).once.and_call_original
    expect(checklist[:status]).to eq("ready")
  end
end
