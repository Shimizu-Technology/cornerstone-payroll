# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayrollLiabilityCenter", type: :request do
  let!(:company) { create(:company) }
  let!(:department) { create(:department, company:) }
  let!(:employee) { create(:employee, company:, department:) }
  let!(:admin_user) { create(:user, company:, organization: company.organization, role: "admin") }
  let!(:period) do
    create(:pay_period, :committed, company:, start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 20))
  end
  let!(:item) do
    create(:payroll_item, company:, employee:, pay_period: period,
      withholding_tax: 100, social_security_tax: 62, employer_social_security_tax: 62)
  end
  let!(:posting) { PayrollLiabilityPostingService.post!(pay_period: period, actor: admin_user) }
  let(:headers) do
    {
      "X-E2E-User-Email" => admin_user.email,
      "X-Company-Id" => company.id.to_s
    }
  end

  around do |example|
    original_e2e_test_mode = ENV["E2E_TEST_MODE"]
    ENV["E2E_TEST_MODE"] = "true"
    example.run
  ensure
    if original_e2e_test_mode.nil?
      ENV.delete("E2E_TEST_MODE")
    else
      ENV["E2E_TEST_MODE"] = original_e2e_test_mode
    end
  end

  it "returns the company liability worksheet" do
    get "/api/v1/admin/payroll_liability_center", headers:, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch("payroll_liability_center")
    expect(body.dig("totals", "calculated_amount")).to eq(224.0)
    expect(body.fetch("obligations").map { |row| row.fetch("authority") }).to contain_exactly(
      PayrollLiabilityPostingService::GUAM_DRT,
      PayrollLiabilityPostingService::US_TREASURY
    )
  end

  it "stores a reviewed due date only for a real current-company obligation" do
    expect {
      post "/api/v1/admin/payroll_liability_center/due_date", headers:, params: {
        payroll_liability_obligation: {
          pay_period_id: period.id,
          authority: PayrollLiabilityPostingService::GUAM_DRT,
          due_date: "2026-09-15"
        }
      }, as: :json
    }.to change(
      AuditLog.where(action: "payroll_liability_obligation_due_dates#updated"), :count
    ).by(1)

    expect(response).to have_http_status(:ok)
    expect(PayrollLiabilityObligationDueDate.last).to have_attributes(
      company_id: company.id,
      pay_period_id: period.id,
      updated_by_id: admin_user.id,
      due_date: Date.new(2026, 9, 15)
    )
    audit = AuditLog.where(action: "payroll_liability_obligation_due_dates#updated").last
    expect(audit).to have_attributes(
      company_id: company.id,
      user_id: admin_user.id,
      record_id: PayrollLiabilityObligationDueDate.last.id,
      subject_name: "#{PayrollLiabilityPostingService::GUAM_DRT} due date"
    )
    expect(audit.metadata).to include(
      "changed_fields" => [ "due_date" ],
      "before_values" => { "due_date" => nil },
      "after_values" => { "due_date" => "2026-09-15" },
      "pay_period_id" => period.id
    )

    post "/api/v1/admin/payroll_liability_center/due_date", headers:, params: {
      payroll_liability_obligation: {
        pay_period_id: period.id,
        authority: "Invented recipient",
        due_date: "2026-09-15"
      }
    }, as: :json
    expect(response).to have_http_status(:not_found)
  end

  it "requires a staff identity" do
    client_user = create(:user, company:, organization: company.organization, role: "client")

    get "/api/v1/admin/payroll_liability_center", headers: {
      "X-E2E-User-Email" => client_user.email,
      "X-Company-Id" => company.id.to_s
    }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Staff access required")
  end

  it "does not expose or update another organization's liabilities" do
    foreign_company = create(:company)
    foreign_department = create(:department, company: foreign_company)
    foreign_employee = create(:employee, company: foreign_company, department: foreign_department)
    foreign_period = create(:pay_period, :committed, company: foreign_company)
    create(:payroll_item, company: foreign_company, employee: foreign_employee,
      pay_period: foreign_period, withholding_tax: 9_999)
    PayrollLiabilityPostingService.post!(pay_period: foreign_period, actor: nil)
    foreign_headers = headers.merge("X-Company-Id" => foreign_company.id.to_s)

    get "/api/v1/admin/payroll_liability_center", headers: foreign_headers, as: :json

    expect(response).to have_http_status(:ok)
    body = response.parsed_body.fetch("payroll_liability_center")
    expect(body.fetch("company_id")).to eq(company.id)
    expect(body.dig("totals", "calculated_amount")).to eq(224.0)

    expect {
      post "/api/v1/admin/payroll_liability_center/due_date", headers: foreign_headers, params: {
        payroll_liability_obligation: {
          pay_period_id: foreign_period.id,
          authority: PayrollLiabilityPostingService::GUAM_DRT,
          due_date: "2026-09-15"
        }
      }, as: :json
    }.not_to change(PayrollLiabilityObligationDueDate, :count)
    expect(response).to have_http_status(:not_found)
  end
end
