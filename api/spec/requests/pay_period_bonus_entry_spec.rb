require "rails_helper"

RSpec.describe "Per-payroll bonus entry", type: :request do
  let!(:tax_table) { create(:tax_table) }
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, role: :admin) }
  let!(:employee) { create(:employee, company: company, employment_type: "hourly", pay_rate: 10) }
  let!(:pay_period) { create(:pay_period, company: company) }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  def run_bonus(amount, include_bonus: true)
    payload = { hours: { employee.id.to_s => { regular: 40, overtime: 0 } } }
    payload[:bonuses] = { employee.id.to_s => amount } if include_bonus
    post "/api/v1/admin/pay_periods/#{pay_period.id}/run_payroll", params: payload, headers: headers
    expect(response).to have_http_status(:ok)
    JSON.parse(response.body)
  end

  it "calculates a variable bonus, preserves omission, and clears explicit zero" do
    expect(run_bonus(175.50).dig("results", "errors")).to be_empty
    item = pay_period.payroll_items.find_by!(employee: employee)
    expect(item.gross_pay).to eq(575.50)
    expect(item.bonus_source).to eq("manual")
    run_bonus(nil, include_bonus: false)
    expect(item.reload.gross_pay).to eq(575.50)
    run_bonus(0)
    expect(item.reload.gross_pay).to eq(400)
    expect(item.bonus).to eq(0)
  end

  it "does not reuse a bonus on a different payroll" do
    run_bonus(200)
    other_period = create(:pay_period, company: company, start_date: pay_period.start_date + 14, end_date: pay_period.end_date + 14, pay_date: pay_period.pay_date + 14)
    post "/api/v1/admin/pay_periods/#{other_period.id}/run_payroll", params: { hours: { employee.id.to_s => { regular: 40 } } }, headers: headers
    expect(response).to have_http_status(:ok)
    expect(other_period.payroll_items.find_by!(employee: employee).bonus).to eq(0)
  end

  it "rejects invalid bonus input without persisting a partial paycheck" do
    body = run_bonus("oops")
    expect(body.dig("results", "errors").first.fetch("error")).to include("Bonus must")
    expect(pay_period.payroll_items).to be_empty
  end
end
