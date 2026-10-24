# frozen_string_literal: true

require "rails_helper"
require "csv"
require "pdf/reader"

RSpec.describe "Rounded payroll saved-value readers", type: :request do
  include_context "corrective payroll ledger fixtures"

  before do
    [ Api::V1::Admin::ReportsController, Api::V1::Admin::PayrollItemsController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  def saved_item
    original!(pay_rate: "10.50", hours_worked: "0.02", bonus: 5, reported_tips: 4, non_taxable_pay: 7,
      custom_columns_data: { "wage_rate_hours" => %w[current carryover].map do |kind|
        { "label" => kind, "rate" => 10.5, "regular_hours" => 0.01, "overtime_hours" => 0,
          "holiday_hours" => 0, "pto_hours" => 0, "active" => true }
      end })
  end

  it "returns the saved cents through item detail, register JSON, CSV, register PDF and the employee stub" do
    item = saved_item
    frozen = freeze_history(item)
    get "/api/v1/admin/pay_periods/#{period.id}/payroll_items/#{item.id}"
    expect(response).to have_http_status(:ok), response.body
    detail = response.parsed_body.fetch("payroll_item")
    expect(detail.fetch("gross_pay").to_d).to eq("9.22".to_d)
    get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok), response.body
    report = response.parsed_body.fetch("report")
    row = report.fetch("employees").sole
    expect(row.fetch("gross_pay").to_d).to eq(item.gross_pay)
    expect(row.fetch("net_pay").to_d).to eq(item.net_pay)
    expect(report.dig("summary", "total_gross").to_d).to eq(item.gross_pay)
    get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok), response.body
    rows = CSV.parse(response.body, headers: true)
    expect(rows.first["Gross Pay"]).to eq("9.22")
    expect(rows.first["Net Pay"].to_d).to eq(item.net_pay)
    expect(rows[-1]["Gross Pay"]).to eq("9.22")
    get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok), response.body
    [ response.body, PayStubGenerator.new(item).generate, PayrollSummaryByEmployeePdfGenerator.new(period).generate ].each do |bytes|
      text = PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join(" ")
      expect(text).to include("9.22", format("%.2f", item.net_pay))
    end
    stub_text = PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join(" ")
    expect(stub_text.scan("0.11").length).to be >= 2
    expect(freeze_history(item.reload)).to eq(frozen)
  end

  it "reads committed pre-deploy gross unchanged even when its saved earning detail differs by a cent" do
    item = saved_item
    item.update_columns(gross_pay: "9.21", net_pay: item.net_pay - "0.01".to_d,
      calculation_context_snapshot: item.calculation_context_snapshot.except("earnings_rounding"))
    frozen = freeze_history(item.reload)
    get "/api/v1/admin/reports/payroll_register", params: { pay_period_id: period.id }
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("report", "employees").sole.fetch("gross_pay").to_d).to eq("9.21".to_d)
    get "/api/v1/admin/reports/payroll_register_csv", params: { pay_period_id: period.id }
    expect(CSV.parse(response.body, headers: true).first["Gross Pay"]).to eq("9.21")
    expect(PDF::Reader.new(StringIO.new(PayStubGenerator.new(item).generate)).pages.map(&:text).join(" ")).to include("9.21")
    expect(freeze_history(item.reload)).to eq(frozen)
  end
end
