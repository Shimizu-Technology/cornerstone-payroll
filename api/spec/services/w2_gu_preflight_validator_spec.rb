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

  # IRS General Instructions for Forms W-2 and W-3 (2026), Box 14b: with tips
  # from more than two occupations, any two codes go on the W-2.
  it "does not block an employee with tips from more than two occupations" do
    %w[303 101 000].each { |code| create(:employee_tipped_occupation, employee: employee, occupation_code: code) }

    result = described_class.new(company: company, year: 2026).run

    expect(result[:findings].map { |finding| finding[:code] }).not_to include(a_string_matching(/OCCUPATION/))
    expect(result[:findings].select { |finding| finding[:employee_id] == employee.id && finding[:severity] == "blocking" }).to be_empty
  end
end
