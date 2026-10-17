# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe "Reviewer plain-paper statement read access", type: :request do
  let(:home) { create(:company) }
  let(:reviewer) { create(:user, company: home, organization: home.organization, role: "accountant") }
  let(:source_employee) { create(:employee, company: home, department: nil, first_name: "QA", last_name: "Reviewer") }
  let(:source_period) { create(:pay_period, :committed, company: home, pay_date: PayrollBusinessClock.today - 1.day) }
  let!(:source_item) { create(:payroll_item, employee: source_employee, pay_period: source_period, payment_delivery_method: "direct_deposit", gross_pay: 1200, net_pay: 960) }
  let(:workspace) do
    target = create(:company, organization: home.organization, payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox", migration_source_company: home, migration_rehearsal_status: "pending", test_workspace_expires_at: 10.days.from_now, test_workspace_manifest: { copied_source_pay_period_ids: [ source_period.id ] })
    TestWorkspace::Cloner.new(company: target, actor: reviewer).call
  end
  let(:period) { workspace.pay_periods.sole }
  let!(:item) { period.payroll_items.sole }
  let(:headers) { { "X-Company-Id" => workspace.id.to_s, "X-Organization-Id" => home.organization_id.to_s } }

  before do
    create(:company_assignment, user: reviewer, company: home)
    create(:company_assignment, user: reviewer, company: workspace, workspace_access_level: "reviewer")
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_user).and_return(reviewer)
    expect(R2StorageService).not_to receive(:new)
  end

  def business_snapshot
    [ item.reload.attributes, period.reload.attributes, CheckEvent.count, CheckPrintRun.count,
      CheckPrintGeneration.count, EmployeeYtdTotal.count, AirePayrollEntryAcknowledgement.count ]
  end

  %w[ready sealed expired].each do |phase|
    %w[batch_pdf direct_deposit_stubs_pdf].each do |action|
      it "allows #{phase} reviewer POST #{action} as a read while retaining the valid baseline business restriction" do
        workspace.update!(test_workspace_sealed_at: Time.current) if phase == "sealed"
        workspace.update!(test_workspace_expires_at: 1.day.ago) if phase == "expired"
        before = business_snapshot
        post "/api/v1/admin/pay_stubs/#{action}", params: { pay_period_id: period.id, payroll_item_ids: [ item.id ] }, headers: headers
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.fetch("error")).to eq("Pay stubs are only available for committed pay periods")
        expect(business_snapshot).to eq(before)
      end
    end
  end

  it "does not let the reviewed read escape the active company scope" do
    foreign_period = create(:pay_period, :committed, company: home)
    post "/api/v1/admin/pay_stubs/batch_pdf", params: { pay_period_id: foreign_period.id }, headers: headers
    expect(response).to have_http_status(:not_found)
  end

  %w[batch_pdf direct_deposit_stubs_pdf].each do |action|
    it "retains the actual scoped live #{action} read with zero financial or provider effects" do
      before = [ source_item.reload.attributes, source_period.reload.attributes, business_snapshot ]
      post "/api/v1/admin/pay_stubs/#{action}", params: { pay_period_id: source_period.id, payroll_item_ids: [ source_item.id ] }, headers: headers.merge("X-Company-Id" => home.id.to_s)
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ")
      expect(text).to include("EARNINGS STATEMENT", "QA Reviewer", "960.00")
      expect([ source_item.reload.attributes, source_period.reload.attributes, business_snapshot ]).to eq(before)
    end
  end

  [ "/api/v1/admin/pay_stubs/batch_generate", "/api/v1/admin/pay_stubs/1/generate", "/api/v1/admin/pay_periods/1/checks/batch_pdf" ].each do |path|
    it "cannot spoof a reviewed-read exemption on #{path}" do
      before = business_snapshot
      post path, params: { pay_period_id: period.id, read_only: true, controller_path: "api/v1/admin/pay_stubs", action_name: "batch_pdf" }, headers: headers.merge("X-Read-Only-Action" => "batch_pdf")
      expect(response).to have_http_status(:forbidden)
      expect(business_snapshot).to eq(before)
    end
  end
end
