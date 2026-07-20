# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollLiabilities", type: :request do
  let(:company) { create(:company) }
  let(:admin_user) { create(:user, company: company, organization: company.organization) }
  let(:department) { create(:department, company: company) }
  let(:employee) { create(:employee, company: company, department: department) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }

  before do
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      withholding_tax: 100,
      social_security_tax: 50,
      employer_social_security_tax: 50)
    PayrollLiabilityPostingService.post!(pay_period: pay_period, actor: admin_user)
    allow_any_instance_of(Api::V1::Admin::PayrollLiabilitiesController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayrollLiabilitiesController)
      .to receive(:current_user).and_return(admin_user)
  end

  it "returns an immutable reconciliation view for the selected company" do
    get "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_liabilities"

    expect(response).to have_http_status(:ok)
    reconciliation = response.parsed_body.fetch("payroll_liability_reconciliation")
    expect(reconciliation).to include(
      "status" => "posted",
      "company_id" => company.id,
      "pay_period_id" => pay_period.id,
      "net_liability" => 200.0,
      "historical_backfill_required" => false
    )
    expect(reconciliation.fetch("postings").first.fetch("entries")).not_to be_empty
  end

  it "does not expose another company's pay period" do
    other_company = create(:company)
    other_period = create(:pay_period, :committed, company: other_company)

    get "/api/v1/admin/pay_periods/#{other_period.id}/payroll_liabilities"

    expect(response).to have_http_status(:not_found)
  end

  it "records, dates, and reverses a liability payment through the operator API" do
    post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_liabilities/payments", params: {
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 40,
      payment_date: "2026-07-20",
      payment_method: "ach",
      confirmation_number: "DRT-REQ-40",
      idempotency_key: "request-payment-#{pay_period.id}"
    }

    expect(response).to have_http_status(:created)
    payment = PayrollLiabilityPayment.find(response.parsed_body.dig("payroll_liability_reconciliation", "payments", 0, "id"))
    expect(payment).to have_attributes(amount: 40.00, confirmation_number: "DRT-REQ-40")

    patch "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_liabilities/due_date", params: {
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      due_date: "2026-07-31"
    }

    expect(response).to have_http_status(:ok)
    obligation = response.parsed_body.dig("payroll_liability_reconciliation", "obligations").find do |row|
      row["category"] == "guam_income_tax_withheld"
    end
    expect(obligation).to include("due_date" => "2026-07-31", "settled_amount" => 40.0, "outstanding_amount" => 60.0)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_liabilities/payments/#{payment.id}/reverse", params: {
      reason: "Bank rejected the transfer"
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("payroll_liability_reconciliation", "settled_amount")).to eq(0.0)
    expect(response.parsed_body.dig("payroll_liability_reconciliation", "payment_tracking_status")).to eq("unpaid")
    expect(payment.reload.reversal_payment.reason).to eq("Bank rejected the transfer")
  end

  it "rejects invalid amounts without changing stored payroll or liability evidence" do
    item_snapshot = pay_period.payroll_items.first.attributes

    post "/api/v1/admin/pay_periods/#{pay_period.id}/payroll_liabilities/payments", params: {
      authority: PayrollLiabilityPostingService::GUAM_DRT,
      category: "guam_income_tax_withheld",
      amount: 101,
      payment_date: "2026-07-20",
      payment_method: "ach"
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to match(/exceeds the open liability/)
    expect(pay_period.payroll_items.first.reload.attributes).to eq(item_snapshot)
    expect(PayrollLiabilityPayment.where(pay_period:).count).to eq(0)
  end
end
