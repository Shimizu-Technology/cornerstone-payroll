# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeePayStatements do
  subject(:statements) { described_class.new(company: company, employee: employee) }

  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }

  def paycheck(pay_date, worker: employee, status: "committed", **attributes)
    period = create(:pay_period, company: worker.company, status: status, pay_date: pay_date,
      start_date: pay_date - 14, end_date: pay_date - 4, committed_at: (Time.current if status == "committed"))
    create(:payroll_item, employee: worker, company: worker.company, pay_period: period, **attributes)
  end

  it "filters to the pay year and pages eligible statements in the same newest-first order as the full list" do
    prior_year = paycheck(Date.new(2025, 12, 31), gross_pay: 100)
    original = paycheck(Date.new(2026, 1, 1), gross_pay: 100, payment_delivery_method: "direct_deposit")
    original.update_columns(payroll_reversed_at: Time.current, payroll_reversed_by_id: create(:user, company: company).id,
      payroll_reversal_reason: "Replaced by a corrected check")
    replacement = paycheck(Date.new(2026, 1, 15), gross_pay: 100, check_number: "1235",
      correction_for_payroll_item: original)
    row_only = paycheck(Date.new(2026, 1, 15))
    row_only.payroll_item_earnings.create!(category: "regular", label: "Offset earnings", amount: 10)
    paycheck(Date.new(2026, 1, 29), check_number: " \u00A0\u2007")
    later_year = paycheck(Date.new(2027, 1, 1), gross_pay: 100, check_date: Date.new(2026, 12, 31))

    expect(statements.list).to eq([ later_year, row_only, replacement, original, prior_year ])
    expect(statements.list(year: 2026, page_size: 2)).to eq([ row_only, replacement ])
    expect(statements.list(year: 2026, page: 2, page_size: 2)).to eq([ original ])
    expect(statements.list(year: 2026, page: 3, page_size: 2)).to be_empty
    expect(statements.find(original.id)).to eq(original)
  end

  it "scopes pages and detail to the supplied company, employee and committed payroll" do
    date = Date.new(2026, 1, 1)
    own = paycheck(date, gross_pay: 100)
    draft = paycheck(date + 14, status: "draft", gross_pay: 100)
    colleague = paycheck(date, worker: create(:employee, company: company), gross_pay: 100)
    outsider = paycheck(date, worker: create(:employee), gross_pay: 100)
    mismatched = described_class.new(company: outsider.company, employee: employee)

    RlsSpecContext.strict do
      TenantScope.with_company(company.id) do
        expect(statements.list(year: 2026, page_size: 10)).to eq([ own ])
        expect(statements.find(own.id)).to eq(own)
        [ draft, colleague, outsider ].each { |item| expect(statements.find(item.id)).to be_nil }
        expect(mismatched.list(page_size: 10)).to be_empty
        expect(mismatched.find(own.id)).to be_nil
      end
    end
  end
end
