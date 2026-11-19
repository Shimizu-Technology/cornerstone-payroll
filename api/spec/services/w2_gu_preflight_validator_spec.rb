# frozen_string_literal: true

require "rails_helper"

RSpec.describe W2GuPreflightValidator do
  let(:company) { create(:company, ein: "98-7654321") }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company), first_name: "Ana", middle_name: nil, last_name: "Cruz") }

  before do
    period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 2, 17), end_date: Date.new(2026, 3, 3), pay_date: Date.new(2026, 3, 6))
    create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 2_000, net_pay: 1_600,
      social_security_taxable_wages: 2_000, social_security_taxable_tips: 0, medicare_taxable_wages: 2_000, fit_taxable_wages: 2_000)
  end

  def findings
    described_class.new(company: company, year: 2026).run[:findings].select { |finding| finding[:code] == "EMPLOYEE_TIPPED_OCCUPATION_CODES_EXCESS" }
  end

  it "blocks an employee with more tipped occupation codes than Box 14b holds, naming them" do
    %w[303 101 202].each { |code| create(:employee_tipped_occupation, employee: employee, occupation_code: code) }

    expect(findings).to eq([ {
      severity: "blocking", code: "EMPLOYEE_TIPPED_OCCUPATION_CODES_EXCESS", employee_id: employee.id,
      message: "Ana Cruz has 3 tipped occupation codes for 2026 (101, 202, 303), but W-2 Box 14b holds two. " \
               "End the extra codes on the employee's profile so the W-2 lists the right ones."
    } ])
  end

  it "allows two codes, and ignores codes that ended before the year" do
    %w[101 202].each { |code| create(:employee_tipped_occupation, employee: employee, occupation_code: code) }
    create(:employee_tipped_occupation, employee: employee, occupation_code: "303", effective_from: Date.new(2025, 1, 1), effective_to: Date.new(2025, 12, 31))

    expect(findings).to be_empty
  end
end
