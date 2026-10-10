# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll setup refresh API", type: :request do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, role: "accountant") }
  let!(:employee) { create(:employee, company: company, pay_rate: 16) }
  let!(:other) { create(:employee, :salary, company: company, default_custom_earnings: [ { "label" => "Recurring bonus", "amount" => 200 } ]) }
  let!(:period) { create(:pay_period, :approved, company: company, approved_at: Time.current, approved_by_id: actor.id) }
  let!(:item) { create(:payroll_item, company: company, pay_period: period, employee: employee, pay_rate: 12, hours_worked: 80, custom_deductions: [ { "label" => "Manual", "amount" => 10 } ]) }

  before do
    create(:tax_table)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(actor)
    allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user_id).and_return(actor.id)
  end

  it "recalculates approved payroll using current setup, preserves entered rates and manual deductions, and keeps the existing scope" do
    expect(PayrollTimeAllocationService).not_to receive(:call!)
    employee.update!(default_custom_earnings: [ { "label" => "Current bonus", "amount" => 50 } ])
    post "/api/v1/admin/pay_periods/#{period.id}/refresh_setup", params: { includes_recurring_items: true, includes_base_salary: false }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to eq([])
    expect(period.reload).to have_attributes(status: "calculated", approved_at: nil, approved_by_id: nil)
    expect(item.reload).to have_attributes(hours_worked: 80.to_d, pay_rate: 12.to_d, gross_pay: 1010.to_d)
    expect(item.custom_deductions).to eq([ { "label" => "Manual", "amount" => 10 } ])
    expect(period.payroll_items.pluck(:employee_id)).to eq([ employee.id ])
    expect(period.payroll_review_packages.current.sole.status).to eq("pending")
  end

  it "supersedes an already approved client review even if the monetary calculation remains the same" do
    period.update!(status: "calculated")
    package = PayrollReview::RevisionService.new(pay_period: period, actor: actor).issue!
    client = create(:user, company: company, role: "client")
    PayrollReview::RevisionService.new(pay_period: period, actor: actor).approve!(
      approver: client, recorded_by: actor, method: "email_attestation",
      acknowledgement: PayrollReviewPackage::APPROVAL_ACKNOWLEDGEMENT, evidence_reference: "Retained approval email"
    )
    period.update!(status: "approved")
    post "/api/v1/admin/pay_periods/#{period.id}/refresh_setup", as: :json
    expect(response).to have_http_status(:ok)
    expect(package.reload.status).to eq("superseded")
    expect(period.reload.payroll_review_packages.current.sole.status).to eq("pending")
  end

  it "allows scope settings to change before a first calculation without creating other employees" do
    period.payroll_items.destroy_all
    period.update!(status: "draft")
    post "/api/v1/admin/pay_periods/#{period.id}/refresh_setup", params: { includes_recurring_items: false }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.reload.status).to eq("draft")
    expect(period.includes_recurring_items).to be(false)
    expect(period.payroll_items).to be_empty
  end

  it "rejects malformed scope flags without removing approval" do
    post "/api/v1/admin/pay_periods/#{period.id}/refresh_setup", params: { includes_recurring_items: "maybe" }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.reload.status).to eq("approved")
  end

  it "never falls back to the entire company when explicit employee_ids is empty" do
    period.update!(status: "draft")
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", params: { employee_ids: [] }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.payroll_items.pluck(:employee_id)).to eq([ employee.id ])
  end

  it "does not union unrelated keyed amounts into explicit employee selection" do
    period.update!(status: "draft")
    post "/api/v1/admin/pay_periods/#{period.id}/run_payroll", params: { employee_ids: [ employee.id ], bonuses: { other.id.to_s => 100 } }, as: :json
    expect(response).to have_http_status(:ok)
    expect(period.payroll_items.pluck(:employee_id)).to eq([ employee.id ])
  end

  it "rejects scalar or null named-loan payloads before changing payroll" do
    period.update!(status: "draft")
    [ "300", nil ].each do |input|
      post "/api/v1/admin/pay_periods/#{period.id}/run_payroll",
        params: { employee_ids: [ employee.id ], named_loan_payments: input }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("Named loan inputs must be an object")
      expect(item.reload.pay_rate).to eq(12.to_d)
    end
  end

  it "shows preflight eligibility and requires the explicit unpaid attestation for a financial reversal" do
    period.update!(status: "committed", committed_at: Time.current)
    get "/api/v1/admin/pay_periods/#{period.id}/correction_preflight"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("correction_preflight", "eligible")).to be(true)
    post "/api/v1/admin/pay_periods/#{period.id}/reopen_unpaid", params: { reason: "Refresh unpaid payroll" }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(period.reload).not_to be_voided
    post "/api/v1/admin/pay_periods/#{period.id}/reopen_unpaid", params: { reason: "Refresh unpaid payroll", unpaid_acknowledgement: true }, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("correction_run", "payroll_items").size).to eq(1)
  end

  it "returns an employee loan option for a first draft with no existing payroll row" do
    period.payroll_items.destroy_all
    loan = EmployeeLoan.create!(employee: employee, company: company, name: "Named loan", original_amount: 500, current_balance: 500, payment_amount: 50, balance_as_of: period.pay_date)
    field = create(:payroll_field_definition, company: company, kind: "deduction", tax_treatment: "post_tax_deduction", category: "loan")
    EmployeePayrollField.create!(employee: employee, payroll_field_definition: field, employee_loan: loan, amount: 50)
    get "/api/v1/admin/pay_periods/#{period.id}/payroll_field_inputs"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("payroll_field_inputs", "named_loan_options")).to include(a_hash_including("employee_id" => employee.id, "loan_id" => loan.id, "scheduled_amount" => 50.0))
  end
end
