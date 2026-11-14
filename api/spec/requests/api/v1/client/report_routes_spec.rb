# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client report route allowlist" do
  it "exposes exactly the reviewed read-only report actions" do
    expected = %w[
      annual_payroll_summary
      annual_payroll_summary_csv
      annual_payroll_summary_pdf
      annual_payroll_summary_xlsx
      dashboard
      deductions_contributions_pdf
      deductions_contributions_xlsx
      employee_pay_history
      employee_pay_history_csv
      employee_pay_history_pdf
      employee_pay_history_xlsx
      employer_liability
      employer_liability_csv
      employer_liability_pdf
      employer_liability_xlsx
      form_941_gu
      form_941_gu_pdf
      form_941_gu_xlsx
      installment_loans_pdf
      installment_loans_xlsx
      paycheck_history_pdf
      paycheck_history_xlsx
      payroll_register
      payroll_register_csv
      payroll_register_pdf
      payroll_register_xlsx
      payroll_summary_by_employee_pdf
      payroll_summary_by_employee_xlsx
      quarterly_compliance_packet
      quarterly_compliance_packet_form_941_pdf
      quarterly_compliance_packet_pdf
      quarterly_compliance_packet_schedule_b_pdf
      quarterly_compliance_packet_swica_pdf
      quarterly_compliance_packet_w1_pdf
      quarterly_compliance_packet_xlsx
      retirement_plans_pdf
      retirement_plans_xlsx
      tax_summary
      tax_summary_csv
      tax_summary_pdf
      tax_summary_xlsx
      ytd_summary
      ytd_summary_csv
      ytd_summary_pdf
      ytd_summary_xlsx
    ]
    routes = Rails.application.routes.routes.select { |route| route.defaults[:controller] == "api/v1/client/reports" }
    expect(routes.map { |route| route.defaults[:action] }.sort).to eq(expected.sort)
    expect(routes.map(&:verb).uniq).to eq([ "GET" ])
  end
end
