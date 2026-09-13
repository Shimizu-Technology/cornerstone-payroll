# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Non-employee liability payments", type: :request do
  let!(:company) { create(:company, next_check_number: 7000) }
  let!(:department) { create(:department, company:) }
  let!(:employee) { create(:employee, company:, department:) }
  let!(:admin_user) { create(:user, company:, organization: company.organization, role: "admin") }
  let!(:period) { create(:pay_period, :committed, company:) }
  let!(:item) do
    create(:payroll_item, company:, employee:, pay_period: period,
      social_security_tax: 62, employer_social_security_tax: 62)
  end
  let!(:posting) { PayrollLiabilityPostingService.post!(pay_period: period, actor: admin_user) }
  let(:entry_ids) do
    posting.entries.where(authority: PayrollLiabilityPostingService::US_TREASURY).pluck(:id)
  end

  before do
    allow_any_instance_of(Api::V1::Admin::NonEmployeeChecksController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::NonEmployeeChecksController)
      .to receive(:current_user).and_return(admin_user)
  end

  it "creates one electronic payment without consuming a paper check number" do
    post "/api/v1/admin/non_employee_checks", params: {
      non_employee_check: {
        payable_to: PayrollLiabilityPostingService::US_TREASURY,
        amount: 124,
        check_type: "tax_deposit",
        payment_method: "eftps",
        payment_period_type: "month",
        tax_year: 2026,
        tax_month: 8,
        payment_date: "2026-08-21",
        liability_entry_ids: entry_ids
      }
    }, as: :json

    expect(response).to have_http_status(:created)
    payment = NonEmployeeCheck.last
    expect(payment).to have_attributes(payment_method: "eftps", check_number: nil, paid_at: nil)
    expect(payment.payroll_liability_check_allocations.sum(:amount)).to eq(124)
    expect(company.reload.next_check_number).to eq(7000)
  end

  it "requires electronic confirmation and records an immutable paid event" do
    payment = create(:non_employee_check, company:, amount: 124,
      payable_to: PayrollLiabilityPostingService::US_TREASURY,
      check_type: "tax_deposit", payment_method: "eftps", payment_date: Date.new(2026, 8, 21))
    PayrollLiabilityCheckAllocationService.allocate!(non_employee_check: payment, entry_ids: entry_ids)

    post "/api/v1/admin/non_employee_checks/#{payment.id}/mark_paid", params: {
      payment_date: "2026-08-21"
    }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)

    expect {
      post "/api/v1/admin/non_employee_checks/#{payment.id}/mark_paid", params: {
        payment_date: "2026-08-21",
        confirmation_number: "EFTPS-ABC"
      }, as: :json
    }.to change(AuditLog.where(action: "non_employee_checks#paid"), :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(payment.reload).to have_attributes(paid_by_id: admin_user.id, confirmation_number: "EFTPS-ABC")
    expect(payment.paid_at).to be_present

    expect {
      post "/api/v1/admin/non_employee_checks/#{payment.id}/mark_paid", params: {
        payment_date: "2026-08-21",
        confirmation_number: "EFTPS-ABC"
      }, as: :json
    }.not_to change(AuditLog.where(action: "non_employee_checks#paid"), :count)
    expect(response).to have_http_status(:ok)
  end

  it "requires void and recreation before paid payment details can change" do
    payment = create(:non_employee_check, company:, amount: 124,
      payable_to: PayrollLiabilityPostingService::US_TREASURY,
      check_type: "tax_deposit", payment_method: "eftps", payment_date: Date.new(2026, 8, 21),
      confirmation_number: "EFTPS-ABC")
    PayrollLiabilityCheckAllocationService.allocate!(non_employee_check: payment, entry_ids: entry_ids)
    payment.update!(paid_at: Time.current, paid_by: admin_user)

    patch "/api/v1/admin/non_employee_checks/#{payment.id}", params: {
      non_employee_check: { payment_date: "2026-08-22", confirmation_number: "CHANGED" },
      reason: "Try to change issued payment"
    }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to match(/Void and recreate a paid payment/)
    expect(payment.reload).to have_attributes(
      payment_date: Date.new(2026, 8, 21), confirmation_number: "EFTPS-ABC"
    )
  end

  it "requires a paper check to be printed before it can be marked paid" do
    payment = create(:non_employee_check, company:, amount: 124,
      payable_to: PayrollLiabilityPostingService::US_TREASURY,
      check_type: "tax_deposit", payment_method: "check", payment_date: Date.new(2026, 8, 21))
    PayrollLiabilityCheckAllocationService.allocate!(non_employee_check: payment, entry_ids: entry_ids)

    post "/api/v1/admin/non_employee_checks/#{payment.id}/mark_paid", params: {
      payment_date: "2026-08-21"
    }, as: :json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to match(/Print the check/)

    payment.mark_printed!
    post "/api/v1/admin/non_employee_checks/#{payment.id}/mark_paid", params: {
      payment_date: "2026-08-21"
    }, as: :json
    expect(response).to have_http_status(:ok)
  end
end
