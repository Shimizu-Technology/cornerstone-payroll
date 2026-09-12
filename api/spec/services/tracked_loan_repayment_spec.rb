# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Tracked payroll loan repayment" do
  let!(:tax_table) { create(:tax_table) }
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:period) { create(:pay_period, company: company) }
  let(:item) { create(:payroll_item, employee: employee, company: company, pay_period: period, hours_worked: 80) }
  let(:loan) do
    EmployeeLoan.create!(employee: employee, company: company, name: "Verified loan", original_amount: 500,
      current_balance: 75, opening_balance: 75, balance_as_of: period.pay_date, payment_amount: 100,
      first_deduction_date: period.pay_date, status: "active")
  end
  let(:field) { create(:payroll_field_definition, company: company, name: "Loan", kind: "deduction", category: "loan", tax_treatment: "post_tax_deduction", amount_type: "fixed", default_amount: 250, show_in_payroll_grid: true) }
  let!(:assignment) { EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, employee_loan: loan, amount: 250, active: true) }

  def calculate
    PayrollCalculator.for(employee, item).calculate
    item.save!
  end

  it "deducts only the remaining balance, records it once on commit, and stops subsequent deductions" do
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(75)
    expect(loan.reload.current_balance).to eq(75)
    expect(item.payroll_item_deductions.first.employee_loan).to eq(loan)
    calculator = PayrollCalculator.for(employee, item)
    2.times { calculator.apply_loan_payments! }
    expect(loan.reload.current_balance).to eq(0)
    expect(loan.status).to eq("paid_off")
    expect(loan.loan_transactions.payments.count).to eq(1)
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(0)
  end

  it "honors the first payday and suspended status without consuming a balance" do
    loan.update!(first_deduction_date: period.pay_date + 1)
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(0)
    loan.update!(first_deduction_date: period.pay_date, status: "suspended")
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(0)
    loan.reactivate!
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(75)
  end

  it "rejects a stale approved amount instead of under-recording its ledger payment" do
    calculate
    loan.record_payment!(amount: 50)
    expect { PayrollCalculator.for(employee, item).apply_loan_payments! }.to raise_error(ArgumentError, /Unapprove and recalculate/)
    expect(loan.reload.current_balance).to eq(25)
    expect(loan.loan_transactions.payments.where(payroll_item: item)).to be_empty
  end

  it "rejects committing a deduction after its assignment was stopped" do
    calculate
    assignment.update!(active: false)
    expect { PayrollCalculator.for(employee, item).apply_loan_payments! }.to raise_error(ArgumentError, /Unapprove and recalculate/)
    expect(loan.reload.current_balance).to eq(75)
  end

  it "rejects a changed default payment after approval but preserves an explicit override" do
    loan.update!(current_balance: 500)
    calculate
    loan.update!(payment_amount: 25)
    expect { PayrollCalculator.for(employee, item).apply_loan_payments! }.to raise_error(ArgumentError, /repayment schedule changed/)
    expect(loan.reload.current_balance).to eq(500)
    applier = PayrollFieldInputApplier.new(pay_period: period, company_id: company.id)
    applier.apply!(payroll_item: item, employee: employee, inputs: { field.id.to_s => { mode: "override", amount: 40 } })
    calculate
    loan.update!(payment_amount: 20)
    PayrollCalculator.for(employee, item).apply_loan_payments!
    expect(loan.reload.current_balance).to eq(460)
  end

  it "restores the balance once on payroll void while preserving both entries" do
    calculate
    PayrollCalculator.for(employee, item).apply_loan_payments!
    payment = loan.loan_transactions.payments.first
    2.times { loan.reverse_payroll_payment!(payment, actor: nil, reason: "Incorrect payroll") }
    expect(loan.reload.current_balance).to eq(75)
    expect(loan.status).to eq("active")
    expect(loan.loan_transactions.count).to eq(2)
    expect(payment.reload.reversal.balance_after).to eq(75)
  end

  it "enforces assignment end dates even on manually overridden loan fields" do
    applier = PayrollFieldInputApplier.new(pay_period: period, company_id: company.id)
    applier.apply!(payroll_item: item, employee: employee, inputs: { field.id.to_s => { mode: "override", amount: 30 } })
    calculate
    assignment.update!(end_date: period.pay_date - 1)
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(0)
  end

  it "restores an explicit requested payment when a balance increases after capping" do
    applier = PayrollFieldInputApplier.new(pay_period: period, company_id: company.id)
    applier.apply!(payroll_item: item, employee: employee, inputs: { field.id.to_s => { mode: "override", amount: 90 } })
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(75)
    loan.record_addition!(amount: 50)
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(90)
  end

  it "reverses the loan payment through the real payroll void service" do
    calculate
    period.update!(status: "approved")
    PayPeriodLifecycleService.new(pay_period: period, actor: nil).commit!
    expect(loan.reload.current_balance).to eq(0)
    PayPeriodCorrectionService.void!(pay_period: period.reload, actor: nil, reason: "Payroll correction required")
    expect(loan.reload.current_balance).to eq(75)
    expect(loan.loan_transactions.payments.count).to eq(1)
    expect(loan.loan_transactions.where(transaction_type: "adjustment").count).to eq(1)
  end

  it "tracks two loans independently and caps each at its own remaining balance" do
    second_loan = EmployeeLoan.create!(employee: employee, company: company, name: "Second loan", original_amount: 200,
      current_balance: 30, balance_as_of: period.pay_date, payment_amount: 50)
    second_field = create(:payroll_field_definition, company: company, name: "Second loan deduction", kind: "deduction", category: "loan", tax_treatment: "post_tax_deduction", amount_type: "fixed")
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: second_field, employee_loan: second_loan, amount: 50)
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(105)
    PayrollCalculator.for(employee, item).apply_loan_payments!
    expect(loan.reload.current_balance).to eq(0)
    expect(second_loan.reload.current_balance).to eq(0)
    expect(loan.loan_transactions.payments.sum(:amount)).to eq(75)
    expect(second_loan.loan_transactions.payments.sum(:amount)).to eq(30)
    duplicate = EmployeePayrollField.new(employee: employee, payroll_field_definition: second_field, employee_loan: loan)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:employee_loan]).to include("already has a repayment schedule")
  end

  it "prevents detaching a saved loan link while leaving an uncapped deduction" do
    assignment.employee_loan = nil
    expect(assignment).not_to be_valid
    expect(assignment.errors[:employee_loan]).to include("cannot be detached or replaced; suspend this repayment schedule instead")
  end

  it "uses the ledger amount for an existing legacy fixed deduction too" do
    assignment.destroy!
    deduction_type = DeductionType.create!(company: company, name: "Legacy loan", category: "post_tax", sub_category: "loan")
    loan.update!(deduction_type: deduction_type)
    employee.employee_deductions.create!(deduction_type: deduction_type, amount: 250, active: true)
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(75)
    expect(item.payroll_item_deductions.first.employee_loan).to eq(loan)
  end

  it "rejects a direct amount that would suppress a tracked balance, then commits a named override correctly" do
    item.loan_deduction = 40
    applier = PayrollFieldInputApplier.new(pay_period: period, company_id: company.id)
    expect { applier.apply!(payroll_item: item, employee: employee, inputs: { field.id.to_s => { mode: "default" } }) }.not_to raise_error
    expect { calculate }.to raise_error(ArgumentError, /direct amount is not recorded in that ledger/i)
    expect(loan.reload.current_balance).to eq(75)
    expect { applier.apply!(payroll_item: item, employee: employee, inputs: { field.id.to_s => { mode: "override", amount: 30 } }) }.to raise_error(ArgumentError, /only one loan deduction source/)
    item.loan_deduction = 0
    applier.apply!(payroll_item: item, employee: employee, inputs: { field.id.to_s => { mode: "override", amount: 40 } })
    calculate
    expect(item.payroll_item_deductions.sum(&:amount)).to eq(40)
    period.update!(status: "approved")
    PayPeriodLifecycleService.new(pay_period: period, actor: nil).commit!
    expect(loan.reload.current_balance).to eq(35)
  end

  it "allows an unrelated direct payment when the tracked schedule is not due or has stopped" do
    item.loan_deduction = 40
    loan.update!(first_deduction_date: period.pay_date + 1)
    expect { calculate }.not_to raise_error
    expect(item.loan_payment).to eq(40)
    loan.update!(first_deduction_date: period.pay_date)
    assignment.update!(end_date: period.pay_date - 1)
    expect { calculate }.not_to raise_error
    expect(loan.reload.current_balance).to eq(75)
  end

  it "protects a legacy loan repayment schedule from the same direct override" do
    assignment.destroy!
    deduction_type = DeductionType.create!(company: company, name: "Legacy loan", category: "post_tax", sub_category: "loan")
    loan.update!(deduction_type: deduction_type)
    employee.employee_deductions.create!(deduction_type: deduction_type, amount: 100, active: true)
    item.loan_deduction = 40
    expect { calculate }.to raise_error(ArgumentError, /named deduction/)
  end

  it "also blocks committing an older saved direct payment that bypassed the tracked schedule" do
    item.update!(loan_deduction: 40, loan_payment: 40)
    period.update!(status: "approved")
    expect { PayPeriodLifecycleService.new(pay_period: period, actor: nil).commit! }.to raise_error(ArgumentError, /named deduction/)
    expect(period.reload).to be_approved
    expect(loan.reload.current_balance).to eq(75)
    expect(loan.loan_transactions).to be_empty
  end

  context "with a recurring deduction that has no known balance" do
    let(:loan) do
      EmployeeLoan.create!(
        employee: employee,
        company: company,
        name: "Recurring deduction until stopped",
        tracking_mode: "recurring_no_balance",
        payment_amount: 50,
        first_deduction_date: period.pay_date,
        status: "active"
      )
    end

    it "deducts the full scheduled amount without inventing or reducing a balance" do
      calculate

      deduction = item.payroll_item_deductions.first
      expect(deduction.amount).to eq(50)
      expect(deduction.employee_loan).to eq(loan)
      expect(loan.reload.current_balance).to be_nil

      period.update!(status: "approved")
      PayPeriodLifecycleService.new(pay_period: period, actor: nil).commit!
      transaction = loan.loan_transactions.payments.find_by!(payroll_item: item)
      expect(transaction).to have_attributes(amount: 50, balance_before: nil, balance_after: nil, source: "payroll")
      expect(loan.reload).to have_attributes(status: "active", current_balance: nil)
    end

    it "records a committed deduction once and reverses it without creating a fake balance" do
      calculate
      calculator = PayrollCalculator.for(employee, item)
      2.times { calculator.apply_loan_payments! }
      expect(loan.loan_transactions.payments.count).to eq(1)

      payment = loan.loan_transactions.payments.first
      2.times { loan.reverse_payroll_payment!(payment, actor: nil, reason: "Voided payroll") }
      expect(loan.loan_transactions.where(transaction_type: "adjustment").count).to eq(1)
      expect(loan.loan_transactions.order(:id).pluck(:balance_before, :balance_after)).to eq([ [ nil, nil ], [ nil, nil ] ])
      expect(loan.reload.current_balance).to be_nil
    end

    it "rejects an unidentified direct import amount that would bypass its ledger" do
      item.loan_deduction = 40

      expect { calculate }.to raise_error(ArgumentError, /named deduction/)
      expect(loan.loan_transactions).to be_empty
    end

    it "never allows payoff or balance additions for the no-balance mode" do
      expect { loan.mark_paid_off! }.to raise_error(ArgumentError, /should be stopped/)
      expect { loan.record_addition!(amount: 25) }.to raise_error(ArgumentError, /cannot receive a loan advance/)
      expect(loan.reload).to be_active
    end
  end

  [ :inactive, :expired ].each do |field_state|
    context "when an #{field_state} field exists alongside an active legacy schedule" do
      before do
        assignment.update!(field_state == :inactive ? { active: false } : { end_date: period.pay_date - 1 })
        deduction_type = DeductionType.create!(company: company, name: "Legacy fallback loan", category: "post_tax", sub_category: "loan")
        loan.update!(deduction_type: deduction_type)
        employee.employee_deductions.create!(deduction_type: deduction_type, amount: 100, active: true)
      end

      it "rejects a direct deduction that would bypass the active legacy repayment" do
        item.loan_deduction = 40
        expect { calculate }.to raise_error(ArgumentError, /named deduction/)
        expect(loan.reload.current_balance).to eq(75)
        expect(loan.loan_transactions).to be_empty
      end

      it "calculates and commits the legacy deduction exactly once" do
        calculate
        expect(item.payroll_item_deductions.size).to eq(1)
        expect(item.payroll_item_deductions.first.amount).to eq(75)
        expect(item.payroll_item_deductions.first.employee_loan).to eq(loan)
        period.update!(status: "approved")
        PayPeriodLifecycleService.new(pay_period: period, actor: nil).commit!
        PayrollCalculator.for(employee, item).apply_loan_payments!
        expect(loan.reload.current_balance).to eq(0)
        expect(loan.loan_transactions.payments.count).to eq(1)
        expect(loan.loan_transactions.payments.sum(:amount)).to eq(75)
      end
    end
  end
end
