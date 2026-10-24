# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Late-hours Client management access", type: :request do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let(:grantor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:assignment) { create(:company_assignment, user: actor, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:period) { create(:pay_period, company: company) }
  let!(:calendar) { create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: period) }
  let(:service) { instance_double(TimeTracking::LateHoursRunService) }
  let(:path) { "/api/v1/admin/pay_periods/#{period.id}/aire_payroll_cockpit/late_hours" }
  let(:selection) { { command_id: SecureRandom.uuid, expected_version: 0, pay_date: "2026-10-24", cases: [ { id: SecureRandom.uuid, version: 0 } ] } }

  before do
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::AirePayrollCockpitsController).to receive(:current_user) { User.find(actor.id) }
    allow(TimeTracking::LateHoursRunService).to receive(:new).and_return(service)
  end

  it "refuses creating or resuming before touching the remote source without the grant" do
    expect(service).not_to receive(:create!)
    expect(service).not_to receive(:retry!)
    expect(service).not_to receive(:cancel!)
    post path, params: selection, as: :json
    expect(response).to have_http_status(:forbidden)
    post "#{path}/1/cancel", params: { reason: "Reviewed unpaid claim" }, as: :json
    expect(response).to have_http_status(:forbidden)
    post "#{path}/1/retry", as: :json
    expect(response).to have_http_status(:forbidden)
  end

  it "accepts the accountant's per-client management grant" do
    assignment.update!(client_management: true, granted_by: grantor)
    result = instance_double(TimeTrackingLateHoursRun)
    expect(service).to receive(:create!).with(**selection.deep_stringify_keys.symbolize_keys).and_return(result)
    expect(service).to receive(:present).with(result).and_return({ id: 7, pay_period_id: 99, applied: true })
    post path, params: selection, as: :json
    expect(response).to have_http_status(:created)
    expect(response.parsed_body.dig("late_hours_run", "pay_period_id")).to eq(99)
    expect(response.headers["Cache-Control"]).to include("no-store")
  end

  it "cannot resume a different company's saved operation" do
    other = create(:pay_period, company: create(:company))
    expect(service).not_to receive(:retry!)
    post "/api/v1/admin/pay_periods/#{other.id}/aire_payroll_cockpit/late_hours/1/retry", as: :json
    expect(response).to have_http_status(:forbidden).or have_http_status(:not_found)
  end

  it "passes an authorized cancellation reason to the audited operation" do
    assignment.update!(client_management: true, granted_by: grantor)
    result = instance_double(TimeTrackingLateHoursRun)
    expect(service).to receive(:cancel!).with("7", reason: "Reviewed changed source hours").and_return(result)
    expect(service).to receive(:present).with(result).and_return({ id: 7, applied: false, closed: true, state: "cancelled" })
    post "#{path}/7/cancel", params: { reason: "Reviewed changed source hours" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("late_hours_run", "closed")).to be(true)
  end
end
