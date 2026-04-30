# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::PayPeriods", type: :request do
  let!(:company) { create(:company, name: "Portal Payroll Co") }
  let!(:client_user) { create(:user, company: company, role: "client", email: "portal-pay-periods@example.com") }
  let!(:committed_pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 4, 1),
      end_date: Date.new(2026, 4, 14),
      pay_date: Date.new(2026, 4, 18))
  end
  let!(:draft_pay_period) do
    create(:pay_period,
      company: company,
      status: "draft",
      start_date: Date.new(2026, 4, 15),
      end_date: Date.new(2026, 4, 28),
      pay_date: Date.new(2026, 5, 2))
  end

  before do
    CompanyAssignment.create!(user: client_user, company: company)
    create(:employee, company: company, first_name: "Nina", last_name: "Cruz")
    create(:payroll_item, pay_period: committed_pay_period, company: company, gross_pay: 1000, net_pay: 810)
    create(:payroll_item, pay_period: draft_pay_period, company: company, gross_pay: 900, net_pay: 730)

    allow_any_instance_of(Api::V1::Client::PayPeriodsController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(Api::V1::Client::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
  end

  it "shows only committed pay periods to client users" do
    get "/api/v1/client/pay_periods"

    expect(response).to have_http_status(:ok)
    ids = response.parsed_body.fetch("pay_periods").map { |pay_period| pay_period.fetch("id") }
    expect(ids).to contain_exactly(committed_pay_period.id)
    expect(response.parsed_body.dig("meta", "statuses")).to eq("committed" => 1)
  end

  it "orders committed pay periods by pay period chronology" do
    march_period = create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 3, 16),
      end_date: Date.new(2026, 3, 31),
      pay_date: Date.new(2026, 4, 20))
    earlier_march_period = create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 3, 1),
      end_date: Date.new(2026, 3, 15),
      pay_date: Date.new(2026, 3, 30))

    get "/api/v1/client/pay_periods"

    ids = response.parsed_body.fetch("pay_periods").map { |pay_period| pay_period.fetch("id") }
    expect(ids).to eq([ earlier_march_period.id, march_period.id, committed_pay_period.id ])
  end

  it "does not allow a client to open a draft pay period detail" do
    get "/api/v1/client/pay_periods/#{draft_pay_period.id}"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => "Pay period not found")
  end
end
