# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Variable salary calculation entry points", type: :request do
  let!(:tax_table) { create(:tax_table) }
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, role: :admin) }
  let!(:employee) { create(:employee, company: company, employment_type: "salary", salary_type: "variable", pay_rate: 200_000) }
  let!(:period) { create(:pay_period, company: company) }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  it "requires period pay on a regular run but calculates an off-cycle bonus without base salary" do
    payload = { bonuses: { employee.id.to_s => 125 } }
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", params: payload, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors").first.fetch("error")).to include("variable salary")
    expect(period.payroll_items.reload).to be_empty

    period.update!(run_purpose: "bonus", includes_base_salary: false)
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", params: payload, headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to be_empty
    expect(period.payroll_items.find_by!(employee: employee).gross_pay).to eq(125)
  end

  it "rolls back a paycheck created with missing period pay when auto-calculation fails" do
    post "/api/v1/admin/pay_periods/#{period.id}/payroll_items",
      params: { employee_id: employee.id, auto_calculate: true,
        payroll_item: { employee_id: employee.id, bonus: 125 } }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors").join).to include("Pay this period")
    expect(period.payroll_items.reload).to be_empty
  end

  it "preserves saved pay and totals when an edit clears required period pay" do
    item = create(:payroll_item, pay_period: period, employee: employee, employment_type: "salary", pay_rate: employee.pay_rate, salary_override: 1000)
    item.calculate!
    saved = item.reload.attributes.slice("salary_override", "gross_pay", "net_pay", "bonus")
    patch "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}",
      params: { auto_calculate: true, payroll_item: { salary_override: 0, bonus: 125 } }, headers: headers
    expect(response).to have_http_status(:unprocessable_entity)
    expect(item.reload.attributes.slice(*saved.keys)).to eq(saved)
  end
end
