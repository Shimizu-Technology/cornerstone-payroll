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
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000,
      fit_taxable_wages: amounts.fetch(:gross_pay, 2_000)
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

  describe "with only the W-2 decision recorded" do
    before do
      pay(Date.new(2026, 3, 6))
      PayrollFilingResponsibilityRecorder.new(
        company: company, actor: accountant, tax_year: 2026, filing_types: [ "w2_gu" ],
        responsible_party: "cornerstone", imported_payroll_inclusion: "included"
      ).call
    end

    it "checks the W-2s on the W-2 decision alone and keeps the 1099 decision open" do
      result = checklist

      expect(step(result, "filing_decision")[:issues].map { |issue| issue[:code] }).to eq(%w[FORM_1099_FILER_NOT_CHOSEN])
      expect(result[:steps].drop(1).map { |entry| entry[:status] }).not_to include("waiting")
      expect(step(result, "reconciliation")[:status]).to eq("done")
      expect(step(result, "mark_ready").dig(:data, :can_mark_ready)).to be(true)
      expect(result[:status]).to eq("needs_action")
      expect(described_class.new(company: company, year: 2026).w2_mark_ready_blockers).to be_empty
    end

    it "still blocks the W-2s on a real W-2 problem" do
      company.update_columns(ein: nil)

      expect(described_class.new(company: company.reload, year: 2026).w2_mark_ready_blockers.map { |issue| issue[:code] })
        .to eq(%w[EMPLOYER_EIN_MISSING])
    end
  end

  describe "when the 1099 report cannot be built" do
    before { pay(Date.new(2026, 3, 6)) }

    it "leaves the 1099 payee check open with what to do, and keeps it out of the W-2 sign-off" do
      decide(w2: "cornerstone", form_1099: "cornerstone")
      allow(Form1099NecAggregator).to receive(:new).and_raise(RuntimeError, "boom")
      expect(Rails.error).to receive(:report).with(an_instance_of(RuntimeError), hash_including(handled: true)).at_least(:once)

      result = checklist

      people = step(result, "people")
      expect(people[:status]).to eq("action_needed")
      expect(people[:issues]).to contain_exactly(a_hash_including(
        code: "PAYEES_UNAVAILABLE", message: "1099 payees could not be loaded. Open the 2026 1099-NEC report to see the problem, then reload this page."
      ))
      expect(result[:status]).to eq("needs_action")
      expect(step(result, "mark_ready").dig(:data, :can_mark_ready)).to be(true)
      expect(described_class.new(company: company, year: 2026).w2_mark_ready_blockers).to be_empty
    end

    it "says how to fix a missing 1099 threshold, so a 1099-only client is not ready" do
      decide(w2: "client", form_1099: "cornerstone")

      result = checklist

      expect(step(result, "people")[:issues]).to contain_exactly(a_hash_including(
        code: "PAYEES_UNAVAILABLE",
        message: "1099 payees could not be loaded: No 1099_nec reporting threshold is configured for 2026. Fix the 2026 1099-NEC setup, then reload this page."
      ))
      expect(result[:status]).to eq("needs_action")
    end
  end

  describe "prior provider overlap uses the pay date" do
    def imported_paycheck(pay_date, period_start:, period_end:)
      create_historical_filing_source(
        company: company, employee: employee, pay_date: pay_date,
        gross_pay: 2_000, federal_income_tax: 150, social_security_tax: 124, medicare_tax: 29,
        employer_social_security_tax: 124, employer_medicare_tax: 29,
        period_start: period_start, period_end: period_end
      )
    end

    before { decide(prior_provider_through: Date.new(2026, 3, 31)) }

    it "does not count a paycheck paid after the date whose work period started before it" do
      imported_paycheck(Date.new(2026, 4, 17), period_start: Date.new(2026, 3, 29), period_end: Date.new(2026, 4, 11))

      expect(step(checklist, "prior_provider")).to include(status: "done", issues: [])
    end

    it "blocks a paycheck paid on or before the date and names its pay dates" do
      imported_paycheck(Date.new(2026, 3, 27), period_start: Date.new(2026, 3, 8), period_end: Date.new(2026, 3, 21))

      issue = step(checklist, "prior_provider")[:issues].sole
      expect(issue).to include(code: "PRIOR_PROVIDER_OVERLAP", source: "imported_payroll")
      expect(issue[:message]).to start_with("Imported paychecks paid Mar 27, 2026–Mar 27, 2026 are in these W-2 totals")
    end
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

  describe "one-off contractor payees" do
    before { create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000) }

    def contractor_check(amount, number)
      create(:non_employee_check, company: company, check_type: "contractor", payable_to: "Synthetic Roofing", amount: amount,
        check_number: number, payment_period_type: "none", tax_year: nil, tax_month: nil, payment_date: Date.new(2026, 5, 2), printed_at: Time.current)
    end

    def identify(payee, note: "Synthetic Roofing LLC, W-9 on file in the client folder; EIN on the W-9.")
      YearEnd::AcknowledgementRecorder.new(company: company, actor: accountant, tax_year: 2026,
        warning_code: payee[:code], warning_digest: payee[:digest], note: note).call
    end

    it "blocks the 1099s until staff record who the payee is, and again when the checks change" do
      first = contractor_check(1_500, "9001")
      second = contractor_check(1_000, "9002")
      decide(w2: "client", form_1099: "cornerstone")

      people = step(checklist, "people")
      payee = people.dig(:data, :one_off_payees).sole
      expect(payee).to include(name: "Synthetic Roofing", total_compensation: 2_500.0, status: "needs_identity", checks_path: "/checks-payments")
      expect(payee[:checks].map { |check| check[:id] }).to eq([ first.id, second.id ])
      expect(people[:issues]).to contain_exactly(a_hash_including(
        code: "PAYEE_IDENTITY_UNRESOLVED", warning_code: payee[:code],
        message: "Synthetic Roofing was paid $2,500.00 by checks 9001 and 9002 with no contractor record or TIN. Record who this payee is."
      ))
      expect(checklist[:status]).to eq("needs_action")

      identify(payee)
      result = checklist
      expect(step(result, "people")).to include(status: "done", issues: [])
      expect(step(result, "people").dig(:data, :one_off_payees, 0)).to include(status: "identified")
      expect(AuditLog.where(action: "year_end_acknowledgements#recorded", company_id: company.id).count).to eq(1)

      contractor_check(400, "9003")
      issue = step(checklist, "people")[:issues].sole
      expect(issue[:message]).to start_with("The checks changed after Synthetic Roofing was identified.")
    end

    it "refuses an identification made on checks that have since changed" do
      contractor_check(2_500, "9001")
      decide(w2: "client", form_1099: "cornerstone")
      payee = step(checklist, "people").dig(:data, :one_off_payees).sole
      contractor_check(100, "9002")

      expect { identify(payee) }.to raise_error(YearEnd::AcknowledgementRecorder::StaleWarning)
    end

    it "asks again, and refuses the old identification, when two checks are edited by offsetting amounts" do
      first = contractor_check(1_500, "9001")
      second = contractor_check(1_000, "9002")
      decide(w2: "client", form_1099: "cornerstone")
      seen = step(checklist, "people").dig(:data, :one_off_payees).sole
      identify(seen)
      expect(step(checklist, "people").dig(:data, :one_off_payees, 0)).to include(status: "identified")

      # Same checks, same $2,500.00 total, different amounts on each.
      first.update_columns(amount: 1_200)
      second.update_columns(amount: 1_300)

      payee = step(checklist, "people").dig(:data, :one_off_payees).sole
      expect(payee).to include(total_compensation: 2_500.0, status: "needs_identity", acknowledgement_stale: true)
      expect(payee[:checks].map { |check| check[:amount] }).to eq([ 1_200.0, 1_300.0 ])
      expect(payee[:digest]).not_to eq(seen[:digest])
      expect { identify(seen) }.to raise_error(YearEnd::AcknowledgementRecorder::StaleWarning)
      expect(YearEnd::ClientsOverview.new(user: accountant, year: 2026).send(:unidentified_one_off_payees)[company.id]).to eq(1)
    end

    it "counts one-off payees in step 1 so the 1099 answer is not defaulted to no 1099s" do
      contractor_check(2_500, "9001")

      data = step(checklist, "filing_decision")[:data]

      expect(data).to include(contractor_count: 0, one_off_payee_count: 1)
    end

    it "does not cite the W-3SS for a 1099-only client" do
      company.update_columns(phone: nil, email: nil)
      contractor_check(2_500, "9001")
      decide(w2: "client", form_1099: "cornerstone")

      employer = step(checklist, "employer")

      expect(employer[:issues].map { |issue| issue[:message] }).to eq([
        "Add the employer phone number. It prints in the payer box on each 1099.",
        "Add the employer email for the Form 1096 contact."
      ])
      expect(employer[:summary]).to eq("These print on every 1099.")
    end

    it "does not hold up the W-2s" do
      contractor_check(2_500, "9001")
      pay(Date.new(2026, 3, 6))
      decide(w2: "cornerstone", form_1099: "cornerstone")

      result = checklist
      expect(step(result, "people")[:issues].map { |issue| issue[:code] }).to eq(%w[PAYEE_IDENTITY_UNRESOLVED])
      expect(step(result, "mark_ready").dig(:data, :can_mark_ready)).to be(true)
    end
  end

  describe "W-2 flags from the year-end wage rebuild" do
    it "blocks a paycheck that withheld FICA on a Section 125 benefit and asks for review of inconsistent FIT wages" do
      pay(Date.new(2026, 3, 6))
      decide
      report = W2GuAggregator.new(company, 2026).generate
      report[:employees].first.merge!(fica_withheld_on_section_125: true, inconsistent_fit_taxable_wages: true)
      allow(W2GuAggregator).to receive(:new).and_return(instance_double(W2GuAggregator, generate: report))

      warnings = step(checklist, "review_warnings")
      by_code = warnings.dig(:data, :warnings).index_by { |warning| warning[:code] }
      expect(by_code.fetch("fica_withheld_on_section_125")).to include(kind: "blocker", status: "blocked")
      expect(by_code.fetch("fica_withheld_on_section_125")[:explanation]).to include("refund the employee", "941-X")
      expect(by_code.fetch("inconsistent_fit_taxable_wages")).to include(kind: "acknowledge", status: "needs_review")
      expect(warnings[:issues].map { |issue| [ issue[:code], issue[:warning_code] ] }).to include(
        [ "JUDGMENT_WARNING_BLOCKING", "fica_withheld_on_section_125" ],
        [ "JUDGMENT_WARNING_UNREVIEWED", "inconsistent_fit_taxable_wages" ]
      )
      expect(described_class.new(company: company, year: 2026).w2_mark_ready_blockers.map { |issue| issue[:warning_code] })
        .to include("fica_withheld_on_section_125")
    end

    it "flags FICA withheld on a Section 125 benefit from a real paycheck" do
      item = pay(Date.new(2026, 3, 6))
      type = company.deduction_types.create!(name: "Section 125 health", category: "pre_tax", sub_category: "insurance")
      # The paycheck's stored Medicare base still includes the $100 benefit.
      item.payroll_item_deductions.create!(deduction_type: type, label: type.name, category: "pre_tax", amount: 100)
      decide

      codes = step(checklist, "review_warnings").dig(:data, :warnings).map { |warning| warning[:code] }
      expect(codes).to include("fica_withheld_on_section_125")
    end
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

  describe "print and file" do
    it "waits for the W-2 decision and is not needed when the client files its own W-2s" do
      pay(Date.new(2026, 3, 6))
      expect(step(checklist, "print_and_file")).to include(status: "waiting", number: 8)

      decide(w2: "client")
      expect(step(checklist, "print_and_file")).to include(status: "not_needed", data: {})
    end

    it "lists draft copies before the W-2s are marked ready and final ones after, without changing the checklist's status" do
      pay(Date.new(2026, 3, 6))
      decide

      result = checklist
      print_step = step(result, "print_and_file")
      expect(print_step).to include(status: "available", number: 8, title: "Print and file", issues: [])
      expect(print_step.dig(:data, :final)).to be(false)
      documents = print_step.dig(:data, :documents)
      expect(documents.map { |document| document[:key] }).to eq(%w[w2_employee_copies w2_drt_copy_1])
      expect(documents.first).to include(
        title: "Employee copies (B and C)", description: "Print and give to each employee by Feb 1, 2027.",
        contains_full_ssn: false, draft: true, available: true, unavailable_reason: nil,
        download: { path: "/admin/reports/w2_gu_official_copies", params: { year: 2026, copy: "employee" } }
      )
      expect(documents.last).to include(title: "Copy 1 for Guam DRT", description: "Your record; not mailed when you e-file.",
        contains_full_ssn: true, draft: true)
      expect(result).to include(status: "needs_action", next_step: "mark_ready", issue_count: 1)

      fingerprint = W2FilingInputsFingerprint.new(company: company, year: 2026).call
      W2FilingReadiness.create!(company: company, year: 2026, status: "filing_ready", preflight_fingerprint: fingerprint,
        ready_fingerprint: fingerprint, marked_ready_at: Time.current, marked_ready_by: accountant)

      result = checklist
      expect(result).to include(status: "ready", issue_count: 0, next_step: nil)
      expect(step(result, "print_and_file").dig(:data, :final)).to be(true)
      expect(step(result, "print_and_file").dig(:data, :documents).map { |document| document[:draft] }).to eq([ false, false ])
    end

    it "explains why copies are unavailable when there are no W-2 employees" do
      decide

      documents = step(checklist, "print_and_file").dig(:data, :documents)
      expect(documents.map { |document| document[:unavailable_reason] }).to all(eq("No employees have 2026 W-2 wages."))
      expect(documents.map { |document| document[:available] }).to all(be(false))
    end
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
