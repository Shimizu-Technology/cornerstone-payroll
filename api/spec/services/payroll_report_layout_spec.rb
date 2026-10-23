# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Payroll report layout regressions" do
  def reader(bytes)
    PDF::Reader.new(StringIO.new(bytes))
  end

  def text(bytes)
    reader(bytes).pages.map(&:text).join(" ").gsub(/\s+/, " ")
  end

  it "keeps all worker columns, complete amounts, repeated headers, and totals for a large register" do
    employees = 65.times.map do |index|
      {
        employee_name: "Synthetic Worker #{format('%02d', index)} Longsurname",
        employment_type: index.even? ? "hourly" : "salary",
        hours_worked: 76, overtime_hours: 5, gross_pay: 3996.67,
        reported_tips: 12.34, tips_paid_out: 23.45, bonus: 34.56,
        withholding_tax: 197.09, additional_withholding: 10,
        social_security_tax: 247.79, medicare_tax: 57.96, retirement_payment: 123.45,
        straight_loan_deduction: 45.67, installment_loan_payment: 56.78,
        total_deductions: 512.84, net_pay: 3483.83,
        employer_contributions_total: 67.89, employer_payroll_cost: 4302.42,
        check_number: "CHECK#{index}", custom_earnings_total: 78.91, custom_deductions_total: 89.12
      }
    end
    summary = { employee_count: 65, total_hours: 4940, total_overtime_hours: 325,
      total_gross: 259783.55, total_withholding: 12810.85, total_additional_withholding: 650,
      total_employer_payroll_cost: 279657.30, total_custom_earnings: 5129.15,
      total_custom_deductions: 5792.80 }
    bytes = PayrollRegisterPdfGenerator.new(meta: { company_name: "Synthetic QA" },
      pay_period: { start_date: "2026-09-16", end_date: "2026-09-30", pay_date: "2026-10-15" },
      employees: employees, summary: summary).generate
    document = reader(bytes)
    all_text = document.pages.map(&:text).join(" ").gsub(/\s+/, " ")
    expect(all_text).to include("Regular Hours", "Overtime Hours", "Combined Hours", "Base FIT", "Additional FIT Withholding", "$13460.85")
    # Every worker appears in every detail section; no values are dropped to fit.
    employees.each do |worker|
      expect(all_text.scan(worker[:employee_name]).size).to eq(5)
      expect(all_text).to include(worker[:check_number])
    end
    %w[3996.67 12.34 23.45 34.56 197.09 10.00 247.79 57.96 123.45 45.67 56.78 512.84 3483.83 67.89 4302.42 78.91 89.12 279657.30].each do |amount|
      expect(all_text).to include("$#{amount}")
    end
    summary_pages = document.pages.select { |page| page.text.include?("Summary Totals") }
    expect(summary_pages.size).to eq(1)
    expect(summary_pages.first.text).to include("Total Net Pay", "1099 Net Pay")
    detail_pages = document.pages.select { |page| page.text.include?("Synthetic Worker") }
    expect(detail_pages.size).to be > 5
    detail_pages.each { |page| expect(page.text).to include("Employee") }
  end

  context "saved payroll detail" do
    let(:company) { create(:company, name: "Synthetic PDF QA") }
    let(:period) do
      create(:pay_period, :committed, company: company,
        start_date: Date.new(2026, 9, 16), end_date: Date.new(2026, 9, 30), pay_date: Date.new(2026, 10, 15))
    end
    let!(:item) do
      employee = create(:employee, company: company, first_name: "Casey", last_name: "Longsurname")
      create(:payroll_item, company: company, employee: employee, pay_period: period,
        hours_worked: 76, overtime_hours: 5, gross_pay: 3996.67, net_pay: 3483.83,
        withholding_tax: 197.09, additional_withholding: 10,
        social_security_tax: 247.79, medicare_tax: 57.96,
        employer_social_security_tax: 247.79, employer_medicare_tax: 57.96,
        total_deductions: 512.84)
    end

    it "retains long earning labels, multiple rates, dates and complete financial detail in the summary" do
      label = "Ground operations and extended equipment preparation premium"
      item.payroll_item_earnings.create!(category: "regular", label: label, hours: 12, rate: 35, amount: 420)
      item.payroll_item_earnings.create!(category: "regular", label: "Ground second rate", hours: 4, rate: 25, amount: 100)
      bytes = PayrollSummaryByEmployeePdfGenerator.new(period).generate
      content = text(bytes)
      expect(content).to include("Pay date: 10/15/2026", "Work period: 09/16/2026 - 09/30/2026")
      expect(content).to include(label, "Ground second rate", "$420.00", "$100.00", "$3996.67", "$3483.83", "$4302.42", "81h", "$35.00/hour", "$25.00/hour")
      expect(content).to include("Federal Income Tax", "Additional Withholding", "-$197.09", "-$10.00")
      # New layout never shrinks body text to the previous four-point minimum.
      sizes = []
      receiver = Class.new do
        define_method(:set_text_font_and_size) { |_font, size| sizes << size }
      end.new
      reader(bytes).pages.each { |page| page.walk(receiver) }
      expect(sizes.min).to be >= 8
    end

    it "labels taxes as part of total deductions and preserves the saved net-pay tie-out" do
      original = item.attributes
      content = text(PaycheckHistoryPdfGenerator.new(period).generate)
      expect(content).to include("Pay date: 10/15/2026", "Work period: 09/16/2026 - 09/30/2026", "Taxes (included)")
      expect(content).to include("Total deductions", "includes taxes", "$512.84", "$3483.83")
      expect(content).to include("Gross pay minus total deductions equals net pay")
      expect(item.reload.attributes).to eq(original)
    end
  end
end
