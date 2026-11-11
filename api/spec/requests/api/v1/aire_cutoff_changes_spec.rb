# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AIRE lock-time changes", type: :request do
  include_context "aire cutoff change fixture"

  before { publish_delivered_calendar! }

  describe "Cornerstone admin endpoint" do
    let(:path) { "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar/change_cutoff" }

    def sign_in(user)
      allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_company_id).and_return(company.id)
      allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_company).and_return(company)
      allow_any_instance_of(Api::V1::Admin::AirePayrollCalendarsController).to receive(:current_user).and_return(user)
    end

    it "shows the lock-time state and lets an org admin move the lock" do
      sign_in(org_admin)
      get "/api/v1/admin/pay_periods/#{pay_period.id}/aire_payroll_calendar"
      state = response.parsed_body.fetch("aire_payroll_calendar")
      expect(state).to include("cutoff_at" => "2026-10-22T17:00:00+10:00", "cutoff_source" => "policy", "cutoff_override" => nil,
        "needs_revision" => false)
      expect(state.fetch("cutoff_control")).to include(
        "available" => true, "lock_now_available" => true, "reset_available" => false,
        "earliest_at" => "2026-10-17T09:00:00+10:00", "latest_at" => "2026-10-29T23:59:00+10:00",
        "lock_now_available_at" => "2026-10-16T00:00:00+10:00", "unavailable_reason" => nil
      )

      post path, params: { lock_action: "change", cutoff_at: "2026-10-25T17:00:00+10:00", reason: "Payday holiday" }, as: :json

      expect(response).to have_http_status(:created)
      state = response.parsed_body.fetch("aire_payroll_calendar")
      expect(state).to include("cutoff_at" => "2026-10-25T17:00:00+10:00", "cutoff_source" => "override",
        "policy_cutoff_at" => "2026-10-22T17:00:00+10:00", "needs_revision" => false)
      expect(state.fetch("cutoff_override")).to include("action" => "change", "reason" => "Payday holiday",
        "set_by_name" => "Chels", "requested_via" => "cornerstone_payroll")
      expect(state.fetch("cutoff_control")).to include("reset_available" => true)
      expect(state.fetch("publication")).to include("schedule_version" => 2, "delivery_status" => "pending")
      expect(state.fetch("cutoff_history").length).to eq(1)
    end

    it "refuses managers and accountants even though they can publish or read calendars" do
      %w[manager accountant admin].each do |role|
        sign_in(create(:user, company: company, organization: company.organization, role: role))
        post path, params: { lock_action: "lock_now", reason: "Try" }, as: :json
        expect(response).to have_http_status(:forbidden)
      end
      expect(AirePayrollCutoffOverride.count).to eq(0)
    end

    it "explains a rejected time" do
      sign_in(org_admin)
      post path, params: { lock_action: "change", cutoff_at: "2026-10-30T09:00:00+10:00", reason: "Too late" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to eq("error" => "Choose a time at least two days before payday")
    end
  end

  describe "AIRE integration endpoint" do
    let(:calendar) { pay_period.aire_payroll_calendar_period }
    let(:path) { "/api/v1/integrations/time_payroll/calendar_periods/#{calendar.external_pay_period_id}/cutoff_change" }
    let(:request_id) { SecureRandom.uuid }
    let(:headers) { { "X-Shared-Secret" => source.shared_secret, "Idempotency-Key" => request_id, "Content-Type" => "application/json" } }
    let(:body) do
      { schema_version: "1.0", action: "lock_now", reason: "Approvals are done",
        actor: aire_actor.merge("payroll_user_id" => org_admin.id, "unexpected" => "dropped") }
    end

    it "records the AIRE admin, republishes, and replays idempotently" do
      post path, params: body.to_json, headers: headers

      expect(response).to have_http_status(:created)
      change = response.parsed_body.fetch("cutoff_change")
      expect(change).to include("action" => "lock_now", "cutoff_at" => "2026-10-17T09:00:00+10:00",
        "previous_cutoff_at" => "2026-10-22T17:00:00+10:00", "cutoff_source" => "override", "idempotent" => false)
      expect(change.fetch("publication")).to include("schedule_version" => 2, "delivery_status" => "pending")
      override = AirePayrollCutoffOverride.sole
      expect(override.source_actor).to eq(aire_actor.merge("payroll_user_id" => org_admin.id))
      expect(override.request_id).to eq(request_id)
      expect(AuditLog.find_by!(action: "aire_payroll_calendar#cutoff_changed").metadata).to include(
        "requested_via" => "aire_services", "source_actor" => include("name" => "Chels Admin", "role" => "admin")
      )

      post path, params: body.to_json, headers: headers
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("cutoff_change", "idempotent")).to be(true)
      expect(AirePayrollCutoffOverride.count).to eq(1)
    end

    it "rejects a wrong secret, an unknown period, and a missing idempotency key" do
      post path, params: body.to_json, headers: headers.merge("X-Shared-Secret" => "wrong")
      expect(response).to have_http_status(:unauthorized)

      post "/api/v1/integrations/time_payroll/calendar_periods/#{SecureRandom.uuid}/cutoff_change", params: body.to_json, headers: headers
      expect(response).to have_http_status(:unauthorized)

      post path, params: body.to_json, headers: headers.except("Idempotency-Key")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(AirePayrollCutoffOverride.count).to eq(0)
    end

    it "refuses AIRE managers and employees" do
      %w[manager employee].each do |role|
        post path, params: body.merge(actor: aire_actor(role: role)).to_json, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid)
        expect(response).to have_http_status(:forbidden)
      end
      expect(AirePayrollCutoffOverride.count).to eq(0)
    end
  end
end
