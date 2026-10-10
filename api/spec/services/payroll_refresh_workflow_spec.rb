# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Unpaid payroll revisions and named repayments" do
  let(:company) { create(:company, auto_create_fit_check: true) }
  let(:department) { create(:department, company: company) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, company: company, department: department, pay_rate: 16, pay_frequency: "semimonthly", w4_form_version: 2020) }
  let(:period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 9, 1), end_date: Date.new(2026, 9, 15),
      pay_date: Date.new(2026, 10, 10), run_purpose: "adjustment", includes_base_salary: false, includes_recurring_items: false)
  end
  let(:item) { create(:payroll_item, company: company, pay_period: period, employee: employee, pay_rate: 16, hours_worked: 80.3, overtime_hours: 14) }
  let(:type) { DeductionType.create!(company: company, name: "Employee Loan", category: "post_tax", sub_category: "loan", active: true) }
  let(:loan) do
    EmployeeLoan.create!(company: company, employee: employee, name: "Employee Loan", deduction_type: type,
      original_amount: 3259.97, current_balance: 3259.97, payment_amount: 300, first_deduction_date: period.pay_date)
  end

  before do
    config = create(:annual_tax_config, tax_year: 2026, **AnnualTaxConfig::OFFICIAL_2026_PAYROLL_TAXES)
    data = AnnualTaxConfig::OFFICIAL_2026_WITHHOLDING.fetch("single")
    status = create(:filing_status_config, annual_tax_config: config, standard_deduction: data.fetch(:adjustment))
    data.fetch(:standard).each_with_index do |(minimum, maximum, rate), index|
      create(:tax_bracket, filing_status_config: status, bracket_order: index + 1, min_income: minimum, max_income: maximum, rate: rate)
    end
    EmployeeDeduction.create!(employee: employee, deduction_type: type, amount: 300, active: true)
    loan
  end

  def commit_original
    item.calculate!
    period.update!(status: "approved", approved_at: Time.current, approved_by_id: actor.id)
    PayPeriodLifecycleService.new(pay_period: period, actor: actor).commit!
    item.reload
  end

  it "applies a named loan on a special run exactly once and credits its ledger only at commit" do
    NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "override", amount: 300 } })
    item.calculate!
    expect(item).to have_attributes(gross_pay: 1620.80.to_d, withholding_tax: 103.66.to_d, net_pay: 1093.15.to_d)
    expect(item.payroll_item_deductions.map(&:employee_loan_id)).to eq([ loan.id ])
    expect(loan.reload.current_balance).to eq(3259.97.to_d)
    period.update!(status: "approved")
    PayPeriodLifecycleService.new(pay_period: period, actor: actor).commit!
    expect(loan.reload.current_balance).to eq(2959.97.to_d)
    expect(loan.loan_transactions.payments.count).to eq(1)
    expect { PayPeriodLifecycleService.new(pay_period: period, actor: actor).commit! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError)
    expect(loan.reload.current_balance).to eq(2959.97.to_d)
  end

  it "overrides rather than duplicates an enabled legacy default and restores that default" do
    period.update!(includes_recurring_items: true)
    NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "override", amount: 250 } })
    item.calculate!
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(250.to_d)
    NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "default" } })
    item.calculate!
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(300.to_d)
  end

  it "supports explicit zero, a balance cap, and insufficient available pay without changing principal during calculation" do
    period.update!(includes_recurring_items: true)
    NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "override", amount: 0 } })
    item.calculate!
    expect(item.loan_payment).to eq(0)
    loan.update!(current_balance: 100)
    NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "override", amount: 300 } })
    item.calculate!
    expect(item.loan_payment).to eq(100)
    item.hours_worked = 1
    item.overtime_hours = 0
    item.calculate!
    expect(item.net_pay).to eq(0)
    expect(item.loan_payment).to be < 16
    expect(loan.reload.current_balance).to eq(100)
  end

  it "rejects an anonymous amount during calculation when a named repayment is missing" do
    item.loan_deduction = 300
    expect { item.calculate! }.to raise_error(ArgumentError, /named deduction/)
    expect(loan.reload.loan_transactions.payments).to be_empty
  end

  it "rejects inactive, future, foreign, and malformed loan inputs" do
    [ nil, 300, "300", [] ].each do |bad|
      expect { NamedPayrollLoanInput.apply!(payroll_item: item, inputs: bad) }.to raise_error(ArgumentError)
    end
    expect { NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => 300 }) }.to raise_error(ArgumentError)
    expect { NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { "999999" => { mode: "override", amount: 300 } }) }.to raise_error(ArgumentError, /belong/)
    loan.update!(first_deduction_date: period.pay_date + 1.day)
    expect { NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "override", amount: 300 } }) }.to raise_error(ArgumentError, /not active/)
    loan.update!(first_deduction_date: period.pay_date, status: "suspended")
    expect { NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "override", amount: 300 } }) }.to raise_error(ArgumentError, /not active/)
  end

  it "handles a modern field schedule without a legacy deduction or configured payment amount" do
    employee.employee_deductions.destroy_all
    loan.update!(deduction_type: nil, payment_amount: nil)
    field = create(:payroll_field_definition, company: company, kind: "deduction", tax_treatment: "post_tax_deduction", category: "loan", default_amount: 300)
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, employee_loan: loan, amount: 300)
    period.update!(includes_recurring_items: true)
    expect(NamedPayrollLoanInput.options(period).find { |option| option[:loan_id] == loan.id }).to include(eligible: true, scheduled_amount: 300.0)
    NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "override", amount: 250 } })
    item.calculate!
    expect(item.payroll_item_deductions.map(&:amount)).to eq([ 250.to_d ])
    expect(item.payroll_item_deductions.first.employee_loan_id).to eq(loan.id)
    expect(item.payroll_item_field_entries.first.amount).to eq(250.to_d)
    NamedPayrollLoanInput.apply!(payroll_item: item, inputs: { loan.id.to_s => { mode: "default" } })
    item.calculate!
    expect(item.payroll_item_deductions.map(&:amount)).to eq([ 300.to_d ])
  end

  it "retires both checks and reverses accounting atomically, then reopens with fresh IDs and preserved scope" do
    commit_original
    original_check = period.non_employee_checks.first
    original_gross = item.gross_pay
    expect(original_check.amount).to eq(103.66.to_d)
    revision = PayPeriodCorrectionService.reopen_unpaid!(pay_period: period, actor: actor, reason: "Refresh the saved repayment", scope_attributes: { includes_recurring_items: true })
    expect(period.reload).to be_voided
    expect(item.reload).to be_voided
    expect(original_check.reload).to be_voided
    expect(item.check_events.where(event_type: "voided").count).to eq(1)
    expect(revision).to have_attributes(status: "draft", source_pay_period_id: period.id, includes_recurring_items: true, includes_base_salary: false)
    revised = revision.payroll_items.sole
    expect(revised.id).not_to eq(item.id)
    expect(revised).to have_attributes(hours_worked: 80.3.to_d, overtime_hours: 14.to_d, pay_rate: 16.to_d, check_number: nil)
    expect(EmployeeYtdTotal.find_by!(employee: employee, year: 2026).gross_pay).to eq(0)
    revised.calculate!
    expect(revised.net_pay).to eq(1093.15.to_d)
    revision.update!(status: "approved")
    PayPeriodLifecycleService.new(pay_period: revision, actor: actor).commit!
    expect(EmployeeYtdTotal.find_by!(employee: employee, year: 2026).gross_pay).to eq(original_gross)
    expect(loan.reload.current_balance).to eq(2959.97.to_d)
    expect(company.non_employee_checks.active.where(check_type: "tax_deposit").count).to eq(1)
    expect { PayPeriodCorrectionService.reopen_unpaid!(pay_period: period, actor: actor, reason: "Repeated correction") }.to raise_error(PayPeriodCorrectionService::CorrectionError)
    expect(loan.loan_transactions.payments.count).to eq(1)
  end

  it "keeps the earned rows in the void tax payload and uses a separate idempotency key" do
    commit_original
    original_key = period.tax_sync_idempotency_key
    allow(PayrollTaxSyncService).to receive(:configured?).and_return(true)
    allow(PayrollTaxSyncJob).to receive(:perform_later)
    PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Reverse unissued payroll")
    payload = PayrollTaxSyncPayloadBuilder.new(period.reload).build
    expect(payload.dig(:pay_period, :correction_status)).to eq("voided")
    expect(payload.dig(:totals, :gross_pay)).to eq(1620.8)
    expect(payload[:line_items].size).to eq(1)
    expect(period.tax_sync_idempotency_key).not_to eq(original_key)
  end

  it "skips previously voided checks while still reversing every earned payroll row" do
    commit_original
    item.void!(user: actor, reason: "Destroyed the original check")
    period.non_employee_checks.first.void!(reason: "Destroyed tax check")
    PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Reverse unissued payroll")
    expect(item.check_events.where(event_type: "voided").count).to eq(1)
    expect(EmployeeYtdTotal.find_by!(employee: employee, year: 2026).gross_pay).to eq(0)
  end

  it "rolls every retirement back if a later payment cannot be voided" do
    commit_original
    allow_any_instance_of(NonEmployeeCheck).to receive(:void!).and_raise(ArgumentError, "Concurrent payment evidence")
    expect { PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Reverse unissued payroll") }.to raise_error(ArgumentError)
    expect(period.reload).not_to be_voided
    expect(item.reload).not_to be_voided
    expect(item.check_events.where(event_type: "voided")).to be_empty
    expect(EmployeeYtdTotal.find_by!(employee: employee, year: 2026).gross_pay).to eq(1620.8.to_d)
  end

  it "blocks issued employee checks, including evidence retained after an individual void" do
    commit_original
    item.check_events.create!(event_type: "delivered", check_number: item.check_number, user: actor, effective_on: period.pay_date, evidence_type: "hand_delivery", details: { attested: true })
    item.update!(voided: true, voided_at: Time.current, void_reason: "Individual void recorded")
    expect { PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Unsafe reversal rejected") }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /issued/)
    expect(period.reload).not_to be_voided
  end

  it "blocks paid tax checks and recorded tax filings before any check or total changes" do
    commit_original
    check = period.non_employee_checks.sole
    check.update!(printed_at: Time.current, paid_at: Time.current, paid_by: actor, payment_date: period.pay_date)
    expect { PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Unsafe reversal rejected") }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /payment/)
    expect(item.reload).not_to be_voided
    check.update!(paid_at: nil, paid_by: nil)
    Form500Filing.create!(company: company, pay_period: period, status: "filed", fields: { reference: "Paper return" })
    expect { PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Unsafe reversal rejected") }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /filing/)
    expect(item.reload).not_to be_voided
  end

  it "blocks a liability payment that spans other periods" do
    commit_original
    other = create(:pay_period, :committed, company: company, pay_date: period.pay_date + 1.day)
    create(:payroll_item, pay_period: other, employee: employee, gross_pay: 100, withholding_tax: 10)
    other_posting = PayrollLiabilityPostingService.post!(pay_period: other, actor: actor)
    check = period.non_employee_checks.sole
    entry = other_posting.entries.where(authority: PayrollLiabilityPostingService::GUAM_DRT).first
    PayrollLiabilityCheckAllocation.create!(company: company, non_employee_check: check, payroll_liability_entry: entry, amount: 1)
    expect { PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Unsafe reversal rejected") }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /another payroll/)
    expect(item.reload).not_to be_voided
  end

  it "blocks reopening when a later committed payroll depends on these employees" do
    commit_original
    later = create(:pay_period, :committed, company: company, pay_date: period.pay_date + 1.day)
    create(:payroll_item, pay_period: later, employee: employee, gross_pay: 100)
    expect { PayPeriodCorrectionService.reopen_unpaid!(pay_period: period, actor: actor, reason: "Unsafe reversal rejected") }.to raise_error(PayPeriodCorrectionService::InvalidStateError, /later payroll/)
    expect(item.reload).not_to be_voided
  end
  it "preserves entered amounts, wage-rate hours, field overrides, and excluded employees in the revision" do
    excluded_employee = create(:employee, company: company)
    period.pay_period_excluded_employees.create!(employee: excluded_employee, reason: "Not paid in this run")
    field = create(:payroll_field_definition, company: company, kind: "deduction", tax_treatment: "post_tax_deduction")
    item.update!(salary_override: 1620.8, non_taxable_pay: 20, service_charge_wages: 30,
      custom_earnings: [ { "label" => "Entered earning", "amount" => 10 } ],
      custom_deductions: [ { "label" => "Entered deduction", "amount" => 15 } ],
      payroll_adjustments: [ { "label" => "Entered adjustment", "amount" => 25, "treatment" => "non_taxable_addition" } ],
      timekeeping_context_snapshot: { "source_reference" => "Retained timesheet" })
    item.mark_custom_earnings_overridden!
    item.mark_payroll_adjustments_overridden!
    item.save!
    entry = item.payroll_item_field_entries.create!(payroll_field_definition: field, label: field.name,
      kind: "deduction", tax_treatment: "post_tax_deduction", category: "other", amount: 12, source: "manual")
    commit_original
    revision = PayPeriodCorrectionService.reopen_unpaid!(pay_period: period, actor: actor, reason: "Refresh entered payroll setup")
    revised = revision.payroll_items.sole
    %w[salary_override non_taxable_pay service_charge_wages custom_earnings custom_deductions payroll_adjustments timekeeping_context_snapshot].each do |attribute|
      expect(revised.public_send(attribute)).to eq(item.public_send(attribute))
    end
    expect(revised.payroll_item_field_entries.sole.attributes.except("id", "payroll_item_id", "created_at", "updated_at"))
      .to eq(entry.reload.attributes.except("id", "payroll_item_id", "created_at", "updated_at"))
    expect(revision.pay_period_excluded_employees.pluck(:employee_id)).to eq([ excluded_employee.id ])
  end

  it "blocks cleared checks even if no delivery event has been recorded" do
    commit_original
    item.check_reconciliation_events.create!(company: company, pay_period: period, recorded_by: actor, event_type: "cleared",
      check_number: item.check_number, effective_on: period.pay_date, amount: item.net_pay,
      evidence_type: "bank_statement", evidence_reference: "Retained bank evidence", idempotency_key: SecureRandom.uuid)
    expect { PayPeriodCorrectionService.void!(pay_period: period, actor: actor, reason: "Unsafe reversal rejected") }
      .to raise_error(PayPeriodCorrectionService::InvalidStateError, /clearing evidence/)
    expect(period.reload).not_to be_voided
  end

  it "blocks external direct-deposit rows and submitted quarter or annual filings" do
    commit_original
    item.update!(check_number: nil, payment_delivery_method: "direct_deposit")
    expect(PayrollRevisionPaymentPreflight.new(pay_period: period).call[:blockers].join).to include("direct-deposit")
    item.update!(payment_delivery_method: "paper_check")
    PayrollFilingRecord.create!(company: company, filing_type: "w1", tax_year: 2026, quarter: 4,
      status: "submitted", submitted_at: Time.current, confirmation_number: "Filed return", source_fingerprint: "a" * 64)
    expect(PayrollRevisionPaymentPreflight.new(pay_period: period).call[:blockers].join).to include("filing evidence")
  end

  it "blocks automatic reopening of finalized AIRE source imports without changing their records" do
    commit_original
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source, status: "applied")
    expect { PayPeriodCorrectionService.reopen_unpaid!(pay_period: period, actor: actor, reason: "Review source revision first") }
      .to raise_error(PayPeriodCorrectionService::InvalidStateError, /source processing evidence/)
    expect(period.reload).not_to be_voided
    expect(item.reload).not_to be_voided
  end
end
