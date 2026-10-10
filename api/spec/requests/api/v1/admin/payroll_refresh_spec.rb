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
    post "/api/v1/admin/pay_periods/#{period.id}/refresh_setup", params: {
      includes_recurring_items: true, includes_base_salary: false,
      hours: { employee.id.to_s => { regular: 80, overtime: 0, holiday: 0, pto: 0 } }
    }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to eq([])
    expect(period.reload).to have_attributes(status: "calculated", approved_at: nil, approved_by_id: nil)
    expect(item.reload).to have_attributes(hours_worked: 80.to_d, pay_rate: 12.to_d, gross_pay: 1010.to_d)
    expect(item.custom_deductions).to eq([ { "label" => "Manual", "amount" => 10 } ])
    expect(period.payroll_items.pluck(:employee_id)).to eq([ employee.id ])
    expect(period.payroll_review_packages.current.sole.status).to eq("pending")
  end

  it "preserves the reopened payroll rate when its saved hours are explicitly resubmitted" do
    period.update!(status: "committed", committed_at: Time.current)
    post "/api/v1/admin/pay_periods/#{period.id}/reopen_unpaid",
      params: { reason: "Refresh unpaid payroll", unpaid_acknowledgement: true }, as: :json
    expect(response).to have_http_status(:created)
    correction_id = response.parsed_body.dig("correction_run", "id")

    post "/api/v1/admin/pay_periods/#{correction_id}/run_payroll", params: {
      employee_ids: [ employee.id ],
      hours: { employee.id.to_s => { regular: 80, overtime: 0, holiday: 0, pto: 0 } }
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to eq([])
    copied = PayPeriod.find(correction_id).payroll_items.sole
    expect(copied.pay_rate).to eq(12.to_d)
    expect(copied.gross_pay).to eq(960.to_d)
    expect(employee.reload.pay_rate).to eq(16.to_d)
  end

  it "recalculates copied multi-rate hours at saved rates after profile rates change or deactivate" do
    primary = employee.employee_wage_rates.create!(label: "Primary", rate: 12, is_primary: true)
    secondary = employee.employee_wage_rates.create!(label: "Secondary", rate: 20)
    buckets = [
      { "employee_wage_rate_id" => primary.id, "label" => "Primary", "rate" => 12, "regular_hours" => 40, "is_primary" => true },
      { "employee_wage_rate_id" => secondary.id, "label" => "Secondary", "rate" => 20, "regular_hours" => 40 }
    ]
    item.update!(wage_rate_hours: buckets)
    period.update!(status: "committed", committed_at: Time.current)
    post "/api/v1/admin/pay_periods/#{period.id}/reopen_unpaid",
      params: { reason: "Refresh unpaid payroll", unpaid_acknowledgement: true }, as: :json
    correction_id = response.parsed_body.dig("correction_run", "id")
    primary.update!(rate: 16)
    secondary.update!(rate: 30, active: false)

    submitted = buckets
    post "/api/v1/admin/pay_periods/#{correction_id}/run_payroll", params: {
      employee_ids: [ employee.id ], hours: { employee.id.to_s => { wage_rates: submitted } }
    }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("results", "errors")).to eq([])
    copied = PayPeriod.find(correction_id).payroll_items.sole
    expect(copied.wage_rate_hours.map { |bucket| bucket["rate"] }).to eq([ 12.0, 20.0 ])
    expect(copied.gross_pay).to eq(1280.to_d)
    expect(copied.pay_rate).to eq(12.to_d)

    controller = Api::V1::Admin::PayrollItemsController
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    expect(PayrollTimeAllocationService).not_to receive(:call!)
    patch "/api/v1/admin/pay_periods/#{correction_id}/payroll_items/#{copied.id}",
      params: { payroll_item: { wage_rate_hours: submitted }, auto_calculate: true }, as: :json
    expect(response).to have_http_status(:ok)
    expect(copied.reload.gross_pay).to eq(1280.to_d)
    patch "/api/v1/admin/pay_periods/#{correction_id}/payroll_items/#{copied.id}",
      params: { payroll_item: { wage_rate_hours: buckets.map { |bucket| bucket.merge("rate" => 99) } } }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["errors"].join).to include("reviewed wage-rate correction")
    expect(copied.reload.wage_rate_hours.map { |bucket| bucket["rate"] }).to eq([ 12.0, 20.0 ])
  end

  it "rejects foreign and invented inactive wage-rate IDs in correction drafts" do
    saved = employee.employee_wage_rates.create!(label: "Saved", rate: 12)
    item.update!(wage_rate_hours: [ { "employee_wage_rate_id" => saved.id, "label" => "Saved", "rate" => 12, "regular_hours" => 80 } ])
    period.update!(status: "committed", committed_at: Time.current)
    post "/api/v1/admin/pay_periods/#{period.id}/reopen_unpaid",
      params: { reason: "Refresh unpaid payroll", unpaid_acknowledgement: true }, as: :json
    correction_id = response.parsed_body.dig("correction_run", "id")
    foreign = other.employee_wage_rates.create!(label: "Foreign", rate: 100)
    inactive = employee.employee_wage_rates.create!(label: "Never used", rate: 100, active: false)
    nonexistent = Struct.new(:id, :label).new(EmployeeWageRate.maximum(:id) + 1_000, "Invented")
    [ foreign, inactive, nonexistent ].each do |rate|
      post "/api/v1/admin/pay_periods/#{correction_id}/run_payroll", params: {
        employee_ids: [ employee.id ], hours: { employee.id.to_s => { wage_rates: [
          { employee_wage_rate_id: rate.id, label: rate.label, rate: 100, regular_hours: 80 }
        ] } }
      }, as: :json
      expect(response.parsed_body.dig("results", "errors").size).to eq(1)
      expect(PayPeriod.find(correction_id).payroll_items.sole.wage_rate_hours.first["employee_wage_rate_id"]).to eq(saved.id)
    end
  end

  it "replays original rates physically deleted before and after reopening in both calculation and item editing" do
    primary = employee.employee_wage_rates.create!(label: "Deleted primary", rate: 12, is_primary: true)
    secondary = employee.employee_wage_rates.create!(label: "Deleted secondary", rate: 20)
    buckets = [
      { "employee_wage_rate_id" => primary.id, "label" => primary.label, "rate" => 12, "regular_hours" => 40, "is_primary" => true },
      { "employee_wage_rate_id" => secondary.id, "label" => secondary.label, "rate" => 20, "regular_hours" => 40 }
    ]
    item.update!(wage_rate_hours: buckets)
    period.update!(status: "committed", committed_at: Time.current)
    primary.destroy_with_employee_lock!
    post "/api/v1/admin/pay_periods/#{period.id}/reopen_unpaid",
      params: { reason: "Refresh unpaid payroll", unpaid_acknowledgement: true }, as: :json
    expect(response).to have_http_status(:created)
    correction_id = response.parsed_body.dig("correction_run", "id")
    secondary.destroy_with_employee_lock!
    expect(EmployeeWageRate.where(id: buckets.map { |entry| entry["employee_wage_rate_id"] })).to be_empty

    post "/api/v1/admin/pay_periods/#{correction_id}/run_payroll", params: {
      employee_ids: [ employee.id ], hours: { employee.id.to_s => { wage_rates: buckets } }
    }, as: :json
    expect(response.parsed_body.dig("results", "errors")).to eq([])
    copied = PayPeriod.find(correction_id).payroll_items.sole
    expect(copied.gross_pay).to eq(1280.to_d)
    expect(copied.pay_rate).to eq(12.to_d)

    controller = Api::V1::Admin::PayrollItemsController
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)
    patch "/api/v1/admin/pay_periods/#{correction_id}/payroll_items/#{copied.id}",
      params: { payroll_item: { wage_rate_hours: buckets }, auto_calculate: true }, as: :json
    expect(response).to have_http_status(:ok)
    expect(copied.reload.gross_pay).to eq(1280.to_d)
    expect(copied.wage_rate_hours.map { |entry| entry["rate"] }).to eq([ 12.0, 20.0 ])
  end

  it "rejects invented legacy rates and stripped original IDs through calculation and item editing" do
    rate = employee.employee_wage_rates.create!(label: "Captured", rate: 12)
    bucket = { "employee_wage_rate_id" => rate.id, "label" => "Captured", "rate" => 12, "regular_hours" => 80 }
    item.update!(wage_rate_hours: [ bucket ])
    period.update!(status: "committed", committed_at: Time.current)
    post "/api/v1/admin/pay_periods/#{period.id}/reopen_unpaid",
      params: { reason: "Refresh unpaid payroll", unpaid_acknowledgement: true }, as: :json
    correction = PayPeriod.find(response.parsed_body.dig("correction_run", "id"))
    copied = correction.payroll_items.sole
    before = copied.attributes
    controller = Api::V1::Admin::PayrollItemsController
    allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(controller).to receive(:current_user).and_return(actor)

    [ bucket.except("employee_wage_rate_id"), bucket.except("employee_wage_rate_id").merge("label" => "Injected", "rate" => 999) ].each do |input|
      post "/api/v1/admin/pay_periods/#{correction.id}/run_payroll", params: {
        employee_ids: [ employee.id ], hours: { employee.id.to_s => { wage_rates: [ input ] } }
      }, as: :json
      expect(response.parsed_body.dig("results", "errors").size).to eq(1)
      expect(copied.reload.attributes).to eq(before)
      patch "/api/v1/admin/pay_periods/#{correction.id}/payroll_items/#{copied.id}",
        params: { payroll_item: { wage_rate_hours: [ input ] }, auto_calculate: true }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(copied.reload.attributes).to eq(before)
    end
  end

  it "recalculates legitimate original legacy buckets while rejecting requested rate changes" do
    bucket = { "label" => "Legacy", "rate" => 12, "regular_hours" => 80, "is_primary" => true }
    item.update!(wage_rate_hours: [ bucket ])
    period.update!(status: "committed", committed_at: Time.current)
    post "/api/v1/admin/pay_periods/#{period.id}/reopen_unpaid",
      params: { reason: "Refresh unpaid payroll", unpaid_acknowledgement: true }, as: :json
    correction = PayPeriod.find(response.parsed_body.dig("correction_run", "id"))
    post "/api/v1/admin/pay_periods/#{correction.id}/run_payroll", params: {
      employee_ids: [ employee.id ], hours: { employee.id.to_s => { wage_rates: [ bucket.merge("regular_hours" => 40) ] } }
    }, as: :json
    expect(response.parsed_body.dig("results", "errors")).to eq([])
    copied = correction.payroll_items.sole
    expect(copied.reload.gross_pay).to eq(480.to_d)
    post "/api/v1/admin/pay_periods/#{correction.id}/run_payroll", params: {
      employee_ids: [ employee.id ], hours: { employee.id.to_s => { wage_rates: [ bucket.merge("rate" => 99) ] } }
    }, as: :json
    expect(response.parsed_body.dig("results", "errors").sole["error"]).to include("reviewed wage-rate correction")
    expect(copied.reload.gross_pay).to eq(480.to_d)
    expect(item.reload.wage_rate_hours.sole["rate"]).to eq(12.0)
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
