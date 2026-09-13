# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::CheckRegister", type: :request do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company:, organization: company.organization, role: "accountant") }
  let!(:period) do
    create(:pay_period, :committed, company:, start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 20))
  end
  let!(:employee) { create(:employee, company:, first_name: "Mo", last_name: "Shimizu") }
  let!(:payroll_item) do
    create(:payroll_item, :with_check, company:, pay_period: period, employee:,
      check_number: "8200", net_pay: 1_425.75)
  end
  let!(:other_payment) do
    create(:non_employee_check, company:, pay_period: period, payment_period_type: "pay_period",
      payment_method: "check", check_number: "8201", amount: 430.25,
      payment_date: Date.new(2026, 8, 20), payable_to: "Treasurer of Guam")
  end
  let(:headers) do
    { "X-E2E-User-Email" => actor.email, "X-Company-Id" => company.id.to_s }
  end

  around do |example|
    original = ENV["E2E_TEST_MODE"]
    ENV["E2E_TEST_MODE"] = "true"
    example.run
  ensure
    original.nil? ? ENV.delete("E2E_TEST_MODE") : ENV["E2E_TEST_MODE"] = original
  end

  before do
    payroll_item.mark_printed!(user: actor)
    payroll_item.mark_delivered!(
      user: actor, delivered_on: "2026-08-20", delivery_method: "hand_delivery",
      attestation: true, evidence_reference: "Reception log"
    )
    other_payment.mark_printed!
    other_payment.mark_paid!(actor:, payment_date: "2026-08-20")
  end

  it "returns one unified company-scoped register with truthful statuses and totals" do
    get "/api/v1/admin/check_register", headers:, params: { from: "2026-08-01", to: "2026-08-31" }

    expect(response).to have_http_status(:ok)
    register = response.parsed_body.fetch("check_register")
    expect(register.fetch("rows").map { |row| row.fetch("check_number") }).to eq(%w[8200 8201])
    expect(register.fetch("rows").map { |row| row.fetch("status") }).to contain_exactly("issued", "issued")
    expect(register.dig("summary", "amount")).to eq(1856.0)
    expect(register.dig("summary", "outstanding_count")).to eq(2)
  end

  it "records clearing evidence and writes a human-readable audit event" do
    expect {
      post "/api/v1/admin/check_register/events", headers:, params: {
        event: {
          source_type: "payroll_item", source_id: payroll_item.id, event_type: "cleared",
          effective_on: "2026-08-25", evidence_type: "bank_statement",
          evidence_reference: "August statement line 15", idempotency_key: SecureRandom.uuid
        }
      }, as: :json
    }.to change(CheckReconciliationEvent, :count).by(1)
      .and change(AuditLog.where(action: "check_register#cleared"), :count).by(1)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("event", "check_number")).to eq("8200")
  end

  it "exports the same register as CSV" do
    get "/api/v1/admin/check_register/export", headers:, params: { from: "2026-08-01", to: "2026-08-31" }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).to include("Register Date,Check Number,Payee,Amount")
    expect(response.body).to include("8200,Mo Shimizu,1425.75")
    expect(response.body).to include("8201,Treasurer of Guam,430.25")
  end

  it "does not expose another company's checks" do
    foreign_company = create(:company)
    foreign_period = create(:pay_period, company: foreign_company)
    foreign_employee = create(:employee, company: foreign_company)
    foreign_item = create(:payroll_item, :with_check, company: foreign_company,
      pay_period: foreign_period, employee: foreign_employee, check_number: "9999")

    get "/api/v1/admin/check_register", headers:, params: { from: "2026-01-01", to: "2026-12-31" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("check_register", "rows").map { |row| row.fetch("check_number") }).not_to include(foreign_item.check_number)
  end

  it "rejects client users" do
    client = create(:user, company:, organization: company.organization, role: "client")
    get "/api/v1/admin/check_register", headers: headers.merge("X-E2E-User-Email" => client.email),
      params: { from: "2026-08-01", to: "2026-08-31" }

    expect(response).to have_http_status(:forbidden)
  end
end
