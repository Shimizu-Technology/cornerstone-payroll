# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Payroll preview downloads", type: :request do
  let(:company) { create(:company, name: "Example Payroll", next_check_number: 4000, check_stock_type: "top_check") }
  let(:user) { create(:user, role: "accountant", company: company) }
  let(:period) { create(:pay_period, :approved, company: company) }
  let!(:paper) { create(:payroll_item, company: company, pay_period: period, employee: create(:employee, company: company, first_name: "Paper", last_name: "Worker"), gross_pay: 100, net_pay: 90) }
  let!(:deposit) do
    create(:payroll_item, company: company, pay_period: period,
      employee: create(:employee, company: company, first_name: "Deposit", last_name: "Worker", payment_delivery_method: "direct_deposit"),
      gross_pay: 200, net_pay: 180, payment_delivery_method: "direct_deposit")
  end
  let!(:statement_only) do
    create(:payroll_item, company: company, pay_period: period,
      employee: create(:employee, company: company, first_name: "ZeroNet", last_name: "Worker"), gross_pay: 50, net_pay: 0)
  end
  let!(:empty) { create(:payroll_item, company: company, pay_period: period, employee: create(:employee, company: company), hours_worked: 0, gross_pay: 0, net_pay: 0) }
  let!(:review) do
    period.payroll_review_packages.create!(company: company, revision: 3, schema_version: "1",
      calculation_checksum: "a" * 64, generated_at: Time.current, client_review_history_unknown: false)
  end
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  before do
    CompanyAssignment.create!(user: user, company: company)
    allow_any_instance_of(ApplicationController).to receive(:current_user) { User.find(user.id) }
  end

  def download(part = nil)
    get "/api/v1/admin/pay_periods/#{period.id}/checks/preview_pdf", params: { part: part }.compact, headers: headers
  end

  def pages
    PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text)
  end

  %w[calculated approved].each do |status|
    it "allows #{status}, renders checks first and every eligible stub, and audits its revision" do
      period.update_columns(status: status)
      expect { download }.to change { AuditLog.where(action: "checks#preview_pdf").count }.by(1)
      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("Example_Payroll_PREVIEW_2024-01-19_rev3.pdf")
      expect(response.headers["Cache-Control"]).to include("no-store")
      expect(pages.size).to eq(4)
      expect(pages.first).to include("Paper Worker")
      expect(pages.first).not_to include("Deposit Worker")
      expect(pages.drop(1).join).to include("Paper Worker", "Deposit Worker", "ZeroNet Worker")
      pages.each do |text|
        expect(text).to include("PREVIEW")
        expect(text).not_to match(/VOID|NOT FINAL|official earnings statement/)
      end
      log = AuditLog.where(action: "checks#preview_pdf").last
      expect(log.user_id).to eq(user.id)
      expect(log.company_id).to eq(company.id)
      expect(log.created_at).to be_present
      expect(log.metadata).to include("revision" => 3, "pay_period_id" => period.id, "payroll_review_package_id" => review.id, "part" => "combined")
    end
  end

  %w[draft committed voided].each do |status|
    it "rejects #{status} with a clear message and no audit" do
      period.update_columns(status: status == "voided" ? "committed" : status, correction_status: status == "voided" ? "voided" : nil)
      expect { download }.not_to change(AuditLog, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error").downcase).to include(status)
    end
  end

  it "supports checks only and stubs only" do
    download("checks")
    expect(response).to have_http_status(:ok)
    expect(pages.size).to eq(1)
    expect(pages.first).not_to include("Deposit Worker")
    download("stubs")
    expect(response).to have_http_status(:ok)
    expect(pages.size).to eq(3)
    expect(pages.join).to include("Deposit Worker")
  end

  it "writes only the audit entry, including no payroll, numbering, print, review or activity updates" do
    user
    before_state = [ PayrollItem, CheckEvent, Company, PayPeriod, PayrollReviewPackage, User ].map { |model| model.order(:id).map(&:attributes) }
    writes = []
    subscriber = ->(_name, _start, _finish, _id, payload) { writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { download }
    expect(response).to have_http_status(:ok)
    expect(writes.size).to eq(1)
    expect(writes.first).to match(/INSERT INTO "audit_logs"/)
    after_state = [ PayrollItem, CheckEvent, Company, PayPeriod, PayrollReviewPackage, User ].map { |model| model.order(:id).map(&:attributes) }
    expect(after_state).to eq(before_state)
  end

  %w[super_admin org_admin admin manager accountant].each do |role|
    it "permits the #{role} staff role" do
      user.update!(role: role)
      download
      expect(response).to have_http_status(:ok)
    end
  end

  it "refuses clients and foreign company runs" do
    user.update!(role: "client")
    download
    expect(response).to have_http_status(:forbidden)
    user.update!(role: "accountant")
    get "/api/v1/admin/pay_periods/#{create(:pay_period).id}/checks/preview_pdf", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "rejects an invalid part and an empty checks selection without auditing" do
    expect { download("other") }.not_to change(AuditLog, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    paper.update_columns(net_pay: 0)
    expect { download("checks") }.not_to change(AuditLog, :count)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error"]).to include("No checks")
    download
    expect(response).to have_http_status(:ok)
    expect(pages.size).to eq(3)
  end

  it "does not create a review revision for legacy calculated payroll" do
    review.destroy!
    expect { download }.not_to change(PayrollReviewPackage, :count)
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Disposition"]).to include("_rev0.pdf")
    expect(AuditLog.where(action: "checks#preview_pdf").last.metadata["revision"]).to eq(0)
  end

  it "fails closed when the download audit cannot be recorded" do
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordNotSaved, "Audit unavailable")
    download
    expect(response).to have_http_status(:service_unavailable)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body["error"]).to include("Could not record the preview download")
    expect(AuditLog.where(action: "checks#preview_pdf")).to be_empty
  end

  it "exposes the latest preview revision on the run after recalculation" do
    download
    review.update!(status: "superseded", superseded_at: Time.current, supersession_reason: "Recalculated")
    period.payroll_review_packages.create!(company: company, revision: 4, schema_version: "1", calculation_checksum: "b" * 64, generated_at: Time.current)
    get "/api/v1/admin/pay_periods/#{period.id}", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("pay_period", "last_preview_download", "revision")).to eq(3)
    expect(response.parsed_body.dig("pay_period", "payroll_review", "revision")).to eq(4)
  end
end
