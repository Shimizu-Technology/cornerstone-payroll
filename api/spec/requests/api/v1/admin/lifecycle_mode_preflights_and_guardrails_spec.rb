# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Lifecycle PR 3: Mode preflights, scheduled activation, guardrails, classification & invites", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let!(:organization) { create(:organization, name: "Cornerstone Practice") }
  let!(:company) { create(:company, organization: organization, name: "Pacific Trade Works") }
  let!(:department) { create(:department, company: company, name: "Operations") }
  let!(:org_admin) { create(:user, company: company, organization: organization, role: "org_admin", name: "Alex OrgAdmin", email: "alex.admin@example.test") }
  let!(:manager) { create(:user, company: company, organization: organization, role: "manager", name: "Dana Manager", email: "dana.manager@example.test") }
  let!(:accountant) { create(:user, company: company, organization: organization, role: "accountant", name: "Lee Accountant", email: "lee.accountant@example.test") }
  let!(:client_manager) { create(:user, company: company, organization: organization, role: "client", name: "Sloane Owner", email: "sloane@example.test") }

  let(:today) { Date.new(2026, 11, 20) }

  before do
    CompanyAssignment.create!(user: org_admin, company: company)
    CompanyAssignment.create!(user: manager, company: company)
    CompanyAssignment.create!(user: accountant, company: company)
    CompanyAssignment.create!(user: client_manager, company: company)

    allow_any_instance_of(ApplicationController).to receive(:auth_disabled?).and_return(true)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(org_admin)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(org_admin.id)
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::BaseController).to receive(:current_company).and_return(company)
  end

  def unlock_lifecycle_mode!
    stub_const("OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES",
               OperatingProfileCatalog::LOCKED_TOGGLE_MILESTONES.except("client_portal.employee_lifecycle_mode"))
    stub_const("OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS",
               OperatingProfileCatalog::M4_TO_M6_TOGGLE_IDS - [ "client_portal.employee_lifecycle_mode" ])
    stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ "client_portal.employee_lifecycle_mode" ])
  end

  def seed_baseline_profile!(effective_on: Date.new(2026, 1, 1))
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: effective_on).merge(
        client_portal_enabled: true
      )
    )
  end

  describe "locked-mode operating profile payload (L8)" do
    before do
      seed_baseline_profile!
    end

    it "skips LifecycleModePreflight.summary_for while client_portal.employee_lifecycle_mode is locked" do
      expect(ClientOperatingProfiles::LifecycleModePreflight).not_to receive(:summary_for)

      get "/api/v1/admin/companies/#{company.id}/operating_profile"
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body["employee_lifecycle_preflight"]).to be_nil
    end
  end

  describe "mode-switch preflights and immediate vs scheduled activation" do
    before do
      unlock_lifecycle_mode!
      seed_baseline_profile!
      create(:pay_period, company: company, status: "draft", start_date: today - 14, end_date: today - 1, pay_date: today + 4)
      create(:pay_period, company: company, status: "draft", start_date: today, end_date: today + 13, pay_date: today + 18)
      create(:pay_period, company: company, status: "draft", start_date: today + 14, end_date: today + 27, pay_date: today + 32)
    end

    it "enforces all three preflights (pending non-address requests, active intake window, qualifying staff recipient) and ignores pending profile_address requests" do
      travel_to(Time.utc(2026, 11, 20, 12)) do
        worker = create(:employee, :hourly, company: company, first_name: "Jordan", last_name: "Sample")
        pending_pay_request = create(
          :employee_change_request,
          company: company,
          employee: worker,
          requested_by: client_manager,
          proposed_changes: { pay_rate: 25.0 },
          original_values: { pay_rate: 20.0 }
        )
        company.update!(employee_intake_expires_at: 4.hours.from_now, employee_intake_reason: "Temp onboarding")
        # Plain accountant without client_management does NOT qualify
        PortalNotificationRecipient.create!(company: company, user: accountant, team_role: "lead", added_by: org_admin)

        get "/api/v1/admin/companies/#{company.id}/operating_profile"
        expect(response).to have_http_status(:ok)
        preflight = response.parsed_body.fetch("employee_lifecycle_preflight")
        expect(preflight).to include(
          "pending_non_address_change_requests_count" => 1,
          "active_intake_window" => true,
          "qualifying_staff_notification_recipients_count" => 0,
          "ready" => false
        )

        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: (today - 14).iso8601,
          lock_version: 0,
          reason: "Attempt switch before clearing blockers",
          changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to include("pending employee change request")
        expect(response.parsed_body["error"]).to include("incomplete-employee entry window")
        expect(response.parsed_body["error"]).to include("staff notification recipient")

        # Clear all three blockers, while leaving a pending profile_address? request (should NOT block!)
        pending_pay_request.update!(status: :rejected, reviewed_by: manager, reviewed_at: Time.current, review_notes: "Cleared")
        company.update!(employee_intake_expires_at: nil)
        PortalNotificationRecipient.create!(company: company, user: manager, team_role: "backup", added_by: org_admin)

        addr_worker = create(:employee, :hourly, company: company, first_name: "Quinn", last_name: "Address", address_line1: "1 Main St")
        addr_user = create(:user, company: company, organization: organization, role: "portal_employee")
        addr_link = EmployeeAccountLink.create!(company: company, employee: addr_worker, user: addr_user, status: "active", activated_at: 1.week.ago)
        EmployeeChangeRequest.create!(
          company: company,
          employee: addr_worker,
          requested_by: addr_user,
          requested_by_link: addr_link,
          request_kind: "update",
          own_record: true,
          proposed_changes: { "address_line1" => "2 Palm Ave" },
          original_values: { "address_line1" => "1 Main St" },
          sensitive_payload: nil
        )

        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: (today - 14).iso8601,
          lock_version: 0,
          reason: "Enable client-managed mode",
          changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        saved = company.client_operating_profiles.history_order.first
        expect(saved.lifecycle_mode_activated_at).to be_present
        expect(CompanyFeatures.for(company).client_managed_employee_lifecycle?).to be(true)

        # Unrelated subsequent edit carries lifecycle_mode_activated_at forward
        original_activated_at = saved.lifecycle_mode_activated_at
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: today.iso8601,
          lock_version: saved.lock_version,
          reason: "Adjust tip default while staying client_managed",
          changes: { "tips.default" => "already_paid_out" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(company.client_operating_profiles.history_order.first.lifecycle_mode_activated_at.to_i).to eq(original_activated_at.to_i)
        expect(CompanyFeatures.for(company).client_managed_employee_lifecycle?).to be(true)

        # Unrelated same-day edit on today is rejected once a version starts today
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: today.iso8601,
          lock_version: company.client_operating_profiles.history_order.first.lock_version,
          reason: "Attempt second same-day unrelated edit",
          changes: { "tips.default" => "add_to_paycheck" }
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to include("after the latest profile's start date")

        # Immediate same-day rollback to approval_first on today is always allowed even after a same-day edit and with open verification items
        open_item = EmployeeVerificationItem.create!(company: company, employee: worker, event_kind: "new_hire", status: "pending_verification", affects_pay: true)
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: today.iso8601,
          lock_version: company.client_operating_profiles.history_order.first.lock_version,
          reason: "Immediate same-day rollback to approval_first",
          changes: { "client_portal.employee_lifecycle_mode" => "approval_first" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(CompanyFeatures.for(company, on: today).client_managed_employee_lifecycle?).to be(false)
        expect(open_item.reload.status).to eq("pending_verification")
      end
    end

    it "guards intake windows and last qualifying staff recipient while active or scheduled, fails closed if preflight drifts before effective_on, and recovers via activate_lifecycle_mode or revert" do
      PortalNotificationRecipient.create!(company: company, user: manager, team_role: "lead", added_by: org_admin)
      future_date = today + 14
      scheduled = nil
      drifted_request = nil

      travel_to(Time.utc(2026, 11, 20, 12)) do
        # Schedule future-dated switch
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: future_date.iso8601,
          lock_version: 0,
          reason: "Schedule client_managed for next pay period",
          changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        scheduled = company.client_operating_profiles.history_order.first
        expect(scheduled.effective_on).to eq(future_date)
        expect(scheduled.lifecycle_mode_activated_at).to be_nil

        # Proactive guardrails while scheduled:
        # 1. Opening an intake window is refused (422)
        patch "/api/v1/admin/employee_intake_settings", params: {
          employee_intake_settings: { enabled: true, duration_hours: 4, reason: "Try opening while scheduled" }
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to include("while Client-managed employee lifecycle is active or scheduled")

        # 2. Removing the last qualifying staff recipient is refused (422)
        patch "/api/v1/admin/portal_notification_recipients", params: {
          user_ids: [ accountant.id ],
          lead_user_id: accountant.id,
          emails: []
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to include("qualifying staff notification recipient")

        # Meanwhile, an approval_first client submits a pending non-address EmployeeChangeRequest before effective_on
        worker = create(:employee, :hourly, company: company, first_name: "Casey", last_name: "Drift")
        drifted_request = create(
          :employee_change_request,
          company: company,
          employee: worker,
          requested_by: client_manager,
          proposed_changes: { pay_rate: 27.0 },
          original_values: { pay_rate: 20.0 }
        )
      end

      # Fast-forward to effective_on: activation fails closed in approval_first and records blockers + audit log
      travel_to(Time.utc(2026, 12, 4, 12)) do
        expect(PortalNotifications).to receive(:lifecycle_mode_activation_blocked!).with(scheduled, actor: nil).ordered.and_call_original
        expect(PortalNotifications).to receive(:lifecycle_mode_activation_blocked!).with(scheduled, actor: org_admin).ordered.and_call_original
        ActivateScheduledLifecycleModesJob.perform_now

        expect(CompanyFeatures.for(company).employee_lifecycle_mode).to eq("approval_first")
        expect(scheduled.reload.lifecycle_mode_activated_at).to be_nil
        expect(scheduled.lifecycle_mode_activation_failed_at).to be_present
        expect(scheduled.lifecycle_mode_activation_blockers).to include("pending_non_address_change_requests_count" => 1)
        expect(AuditLog.where(company_id: company.id, action: "client_operating_profile.lifecycle_mode_activation_blocked")).to exist

        get "/api/v1/admin/companies/#{company.id}/operating_profile"
        expect(response.parsed_body.dig("employee_lifecycle_preflight", "lifecycle_mode_activation_status")).to eq("blocked")

        # While activation is blocked (still approval_first), opening a valid intake window is allowed,
        # and manual retry still rechecks and blocks until that window is closed.
        patch "/api/v1/admin/employee_intake_settings", params: {
          employee_intake_settings: { enabled: true, duration_hours: 4, reason: "Urgent onboarding while blocked" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(company.reload.employee_intake_expires_at).to be_present

        # Manual retry while still blocked returns 422 (both pending request and opened intake window)
        post "/api/v1/admin/companies/#{company.id}/operating_profile/activate_lifecycle_mode", as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["lifecycle_mode_activation_status"]).to eq("blocked")
        expect(response.parsed_body["blockers"]).to include("active_intake_window" => true)

        # Close the temporary intake window before resolving the remaining blocker
        patch "/api/v1/admin/employee_intake_settings", params: {
          employee_intake_settings: { enabled: false, reason: "Closing window before retry" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(company.reload.employee_intake_expires_at).to be_nil

        # Resolve blocker -> manager (lacking :manage_organization) gets 403, org_admin activates cleanly!
        drifted_request.update!(status: :approved, reviewed_by: manager, reviewed_at: Time.current)
        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(manager)
        allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(manager.id)
        post "/api/v1/admin/companies/#{company.id}/operating_profile/activate_lifecycle_mode", as: :json
        expect(response).to have_http_status(:forbidden)

        allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(org_admin)
        allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(org_admin.id)
        post "/api/v1/admin/companies/#{company.id}/operating_profile/activate_lifecycle_mode", as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body["activation_status"]).to eq("activated")
        expect(scheduled.reload.lifecycle_mode_activated_at).to be_present
        expect(scheduled.lifecycle_mode_activation_failed_at).to be_nil
        expect(scheduled.lifecycle_mode_activation_blockers).to eq({})
        expect(CompanyFeatures.for(company).client_managed_employee_lifecycle?).to be(true)
        expect(AuditLog.where(company_id: company.id, action: "client_operating_profile.lifecycle_mode_activated")).to exist

        # Proactive guardrails remain enforced AFTER activation:
        # 1. Opening an intake window is refused (422) and leaves employee_intake_expires_at unchanged
        patch "/api/v1/admin/employee_intake_settings", params: {
          employee_intake_settings: { enabled: true, duration_hours: 4, reason: "Try opening while active" }
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to include("while Client-managed employee lifecycle is active or scheduled")
        expect(company.reload.employee_intake_expires_at).to be_nil

        # 2. Removing the last qualifying staff recipient is refused (422) and leaves manager listed
        patch "/api/v1/admin/portal_notification_recipients", params: {
          user_ids: [ accountant.id ],
          lead_user_id: accountant.id,
          emails: []
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to include("qualifying staff notification recipient")
        expect(PortalNotificationRecipient.where(company_id: company.id, user_id: manager.id)).to exist
      end
    end

    it "keeps an unrelated future successor profile activated when its predecessor activates, while still requiring activation after a rollback" do
      PortalNotificationRecipient.create!(company: company, user: manager, team_role: "lead", added_by: org_admin)
      create(:pay_period, company: company, status: "draft", start_date: today + 28, end_date: today + 41, pay_date: today + 46)
      create(:pay_period, company: company, status: "draft", start_date: today + 42, end_date: today + 55, pay_date: today + 60)

      date_v2 = today + 14
      date_v3 = today + 28
      date_v4 = today + 42
      v2 = nil
      v3 = nil

      travel_to(Time.utc(2026, 11, 20, 12)) do
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: date_v2.iso8601,
          lock_version: 0,
          reason: "Schedule client_managed V2",
          changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        v2 = company.client_operating_profiles.history_order.first

        # Save unrelated V3 before V2 activates
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: date_v3.iso8601,
          lock_version: v2.lock_version,
          reason: "Schedule unrelated tip change V3 before V2 activates",
          changes: { "tips.default" => "already_paid_out" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        v3 = company.client_operating_profiles.history_order.first
        expect(v3.lifecycle_mode_activated_at).to be_nil

        # Schedule a rollback V4 after V3 and a new re-enable V5 after V4
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: date_v4.iso8601,
          lock_version: v3.lock_version,
          reason: "Schedule rollback V4",
          changes: { "client_portal.employee_lifecycle_mode" => "approval_first" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
      end

      v4 = company.client_operating_profiles.history_order.first
      create(:pay_period, company: company, status: "draft", start_date: today + 56, end_date: today + 69, pay_date: today + 74)
      v5 = nil
      travel_to(Time.utc(2026, 11, 20, 12)) do
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: (today + 56).iso8601,
          lock_version: v4.lock_version,
          reason: "Schedule re-enable V5 after rollback",
          changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        v5 = company.client_operating_profiles.history_order.first
      end

      # On D (date_v2), V2 activates and propagates activation to contiguous successor V3, NOT past rollback V4 to V5
      travel_to(Time.utc(2026, 12, 4, 12)) do
        ActivateScheduledLifecycleModesJob.perform_now
        expect(v2.reload.lifecycle_mode_activated_at).to be_present
        expect(v3.reload.lifecycle_mode_activated_at).to eq(v2.lifecycle_mode_activated_at)
        expect(v5.reload.lifecycle_mode_activated_at).to be_nil

        # Introduce a drifted pending change request before D2
        worker = create(:employee, :hourly, company: company, first_name: "Casey", last_name: "Successor")
        create(
          :employee_change_request,
          company: company,
          employee: worker,
          requested_by: client_manager,
          proposed_changes: { pay_rate: 28.0 },
          original_values: { pay_rate: 20.0 }
        )
      end

      # On D2 (date_v3), V3 stays active in client_managed without re-running preflights or failing closed
      travel_to(Time.utc(2026, 12, 18, 12)) do
        expect(CompanyFeatures.for(company, on: date_v3).client_managed_employee_lifecycle?).to be(true)
        expect(ClientOperatingProfiles::LifecycleModeActivationService.ensure_attempted!(company, as_of: date_v3)).to be_nil
        expect(CompanyFeatures.for(company, on: date_v3).client_managed_employee_lifecycle?).to be(true)
      end
    end

    it "skips a profile blocked by an on-demand failure when ActivateScheduledLifecycleModesJob runs, while activating a clean first scheduled attempt" do
      PortalNotificationRecipient.create!(company: company, user: manager, team_role: "lead", added_by: org_admin)
      future_date = today + 14
      worker = create(:employee, :hourly, company: company, first_name: "Sam", last_name: "Interleave")
      blocker = nil

      travel_to(Time.utc(2026, 11, 20, 12)) do
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: future_date.iso8601,
          lock_version: 0,
          reason: "Schedule client_managed for interleaving test",
          changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body

        blocker = create(
          :employee_change_request,
          company: company,
          employee: worker,
          requested_by: client_manager,
          proposed_changes: { pay_rate: 26.0 },
          original_values: { pay_rate: 20.0 }
        )
      end

      scheduled = company.client_operating_profiles.history_order.first

      # Interleaving: job captures due_company_ids BEFORE on-demand attempt stamps failure and staff clears blocker
      travel_to(Time.utc(2026, 12, 4, 12)) do
        job = ActivateScheduledLifecycleModesJob.new
        allow(job).to receive(:due_company_ids).and_return([ company.id ])

        ClientOperatingProfiles::LifecycleModeActivationService.ensure_attempted!(company, as_of: future_date)
        expect(scheduled.reload.lifecycle_mode_activation_failed_at).to be_present
        blocker.update!(status: :rejected, reviewed_by: manager, reviewed_at: Time.current, review_notes: "Cleared")

        job.perform(as_of: future_date.iso8601)
        expect(scheduled.reload.lifecycle_mode_activated_at).to be_nil
        expect(CompanyFeatures.for(company, on: future_date).employee_lifecycle_mode).to eq("approval_first")
      end

      # Clean first scheduled attempt (no failure marker) activates normally
      other_company = create(:company, organization: organization, name: "Clean Scheduled Co")
      CompanyAssignment.create!(user: org_admin, company: other_company)
      CompanyAssignment.create!(user: manager, company: other_company)
      PortalNotificationRecipient.create!(company: other_company, user: manager, team_role: "lead", added_by: org_admin)
      clean_profile = ClientOperatingProfile.create!(
        ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(other_company, effective_on: future_date).merge(
          client_portal_enabled: true,
          options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
          lifecycle_mode_activated_at: nil,
          lifecycle_mode_activation_failed_at: nil
        )
      )

      travel_to(Time.utc(2026, 12, 4, 12)) do
        ActivateScheduledLifecycleModesJob.perform_now(as_of: future_date.iso8601)
        expect(clean_profile.reload.lifecycle_mode_activated_at).to be_present
        expect(CompanyFeatures.for(other_company, on: future_date).client_managed_employee_lifecycle?).to be(true)
      end
    end

    it "clears blocked scheduled activation state when reverted to approval_first" do
      PortalNotificationRecipient.create!(company: company, user: manager, team_role: "lead", added_by: org_admin)
      future_date = today + 14

      travel_to(Time.utc(2026, 11, 20, 12)) do
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: future_date.iso8601,
          lock_version: 0,
          reason: "Schedule client_managed",
          changes: { "client_portal.employee_lifecycle_mode" => "client_managed" }
        }, as: :json
        expect(response).to have_http_status(:ok)

        # Lose qualifying staff recipient by deactivating manager before effective_on
        manager.update!(active: false)
      end

      travel_to(Time.utc(2026, 12, 4, 12)) do
        ClientOperatingProfiles::LifecycleModeActivationService.ensure_attempted!(company)
        scheduled = company.client_operating_profiles.history_order.first
        expect(scheduled.lifecycle_mode_activation_failed_at).to be_present
        expect(scheduled.lifecycle_mode_activation_blockers).to include("qualifying_staff_notification_recipients_count" => 0)
        expect(CompanyFeatures.for(company).employee_lifecycle_mode).to eq("approval_first")

        # L5: past/today blocked row must NOT allow amending unrelated settings in place
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: future_date.iso8601,
          lock_version: scheduled.lock_version,
          reason: "Attempt unrelated setting amend on due blocked row",
          changes: { "tips.default" => "already_paid_out" }
        }, as: :json
        expect(response).to have_http_status(:unprocessable_content)
        expect(response.parsed_body["error"]).to include("after the latest profile's start date")

        # Revert to approval_first on that same date IS allowed and clears the blocked state cleanly
        patch "/api/v1/admin/companies/#{company.id}/operating_profile", params: {
          effective_on: future_date.iso8601,
          lock_version: scheduled.lock_version,
          reason: "Revert blocked scheduled switch",
          changes: { "client_portal.employee_lifecycle_mode" => "approval_first" }
        }, as: :json
        expect(response).to have_http_status(:ok), response.body
        expect(scheduled.reload.lifecycle_mode_activation_failed_at).to be_nil
        expect(scheduled.lifecycle_mode_activation_blockers).to eq({})
        expect(response.parsed_body.dig("employee_lifecycle_preflight", "lifecycle_mode_activation_status")).to eq("inactive")
      end
    end
  end

  describe "EmployeeVerificationItems::Recorder.requeue_returned_items! transaction safety (L2)" do
    it "opens its own transaction around Company.lock when called standalone" do
      worker = create(:employee, :hourly, company: company, first_name: "Casey", last_name: "Returned")
      returned = EmployeeVerificationItem.create!(
        company: company,
        employee: worker,
        event_kind: "compensation_change",
        status: "returned_to_client",
        affects_pay: true,
        changed_fields: [ "pay_rate" ],
        return_note: "Confirm rate"
      )

      in_recorder_tx = false
      locked_inside_tx = false
      updated_inside_tx = false

      original_transaction = ApplicationRecord.method(:transaction)
      allow(ApplicationRecord).to receive(:transaction) do |*args, **kwargs, &block|
        original_transaction.call(*args, **kwargs) do
          previous = in_recorder_tx
          in_recorder_tx = true
          block.call
        ensure
          in_recorder_tx = previous
        end
      end

      original_lock = Company.method(:lock)
      allow(Company).to receive(:lock) do |*args|
        locked_inside_tx = in_recorder_tx
        original_lock.call(*args)
      end

      allow_any_instance_of(EmployeeVerificationItem).to receive(:update!).and_wrap_original do |method, *args, **kwargs|
        updated_inside_tx = in_recorder_tx
        method.call(*args, **kwargs)
      end

      requeued = EmployeeVerificationItems::Recorder.requeue_returned_items!(
        employee: worker,
        actor: client_manager,
        touched_fields: [ :pay_rate ]
      )
      expect(locked_inside_tx).to be(true)
      expect(updated_inside_tx).to be(true)
      expect(requeued.map(&:id)).to eq([ returned.id ])
      expect(returned.reload.status).to eq("pending_verification")
    end
  end

  describe "EmployeeClassificationTransitionService grandfathering preservation" do
    let!(:super_admin) { create(:user, company: company, organization: organization, role: "super_admin") }

    it "preserves readiness_gate_enforced=false on grandfathered employees and runs EmployeeIntakePolicy.prepare! for them even in client_managed mode (L3)" do
      unlock_lifecycle_mode!
      ClientOperatingProfile.create!(
        ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
          client_portal_enabled: true,
          options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
          lifecycle_mode_activated_at: Time.current
        )
      )

      grandfathered = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Casey",
        last_name: "Grandfathered",
        hire_date: Date.new(2025, 1, 1),
        readiness_gate_enforced: false
      )
      expect(EmployeeIntakePolicy).to receive(:prepare!).once.and_call_original
      result = EmployeeClassificationTransitionService.new(
        employee: grandfathered,
        actor: super_admin,
        attributes: {
          employment_type: "contractor",
          contractor_type: "individual",
          contractor_pay_type: "hourly",
          pay_rate: 30.0,
          effective_date: Date.new(2026, 6, 1).iso8601,
          reason: "Moving worker to 1099 consulting agreement"
        }
      ).call
      expect(result.new_employee.readiness_gate_enforced).to be(false)

      enforced = create(
        :employee,
        :hourly,
        company: company,
        first_name: "Jordan",
        last_name: "Enforced",
        hire_date: Date.new(2025, 1, 1),
        readiness_gate_enforced: true
      )
      expect(EmployeeIntakePolicy).not_to receive(:prepare!)
      result_enforced = EmployeeClassificationTransitionService.new(
        employee: enforced,
        actor: super_admin,
        attributes: {
          employment_type: "contractor",
          contractor_type: "individual",
          contractor_pay_type: "hourly",
          pay_rate: 35.0,
          effective_date: Date.new(2026, 6, 1).iso8601,
          reason: "Moving enforced worker to 1099 agreement"
        }
      ).call
      expect(result_enforced.new_employee.readiness_gate_enforced).to be(true)
    end
  end

  describe "EmployeeLinks::InviteEligibility and EmployeeLinks::Invite" do
    before do
      ClientOperatingProfile.create!(
        ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
          employee_portal_enabled: true
        )
      )
      EmployeeAppActivation.create!(company: company, part: EmployeeAppSwitch::MASTER, activated_by: org_admin, activated_at: Time.current)
      allow(EmployeeLinks::AppUrl).to receive(:origin_for).with(company).and_return("https://employees.example.test")
      allow(EmployeeLinks::InviteEmail).to receive(:deliver).and_return("sent")
    end

    it "separates DOB/SSN/email prerequisites from full Ready-to-pay check and blocks inviting Incomplete readiness_gate_enforced hires" do
      incomplete_hire = create(
        :employee,
        :hourly,
        company: company,
        department: department,
        first_name: "Morgan",
        last_name: "Incomplete",
        email: "morgan.incomplete@example.test",
        date_of_birth: Date.new(1995, 2, 10),
        ssn_encrypted: "900-33-4455",
        hire_date: Date.new(2026, 1, 1),
        pay_rate: 20.0,
        payment_delivery_method: nil,
        readiness_gate_enforced: true
      )
      # Has DOB + SSN + email (Milestone 5 activation prerequisites satisfied),
      # but missing W-4 and payment_delivery_method (not Ready to pay).
      expect(EmployeeLinks::InviteEligibility.activation_prerequisites(incomplete_hire).eligible?).to be(true)
      expect(EmployeeLinks::InviteEligibility.eligible?(incomplete_hire, require_full_readiness: false)).to be(true)
      expect(EmployeeLinks::InviteEligibility.eligible?(incomplete_hire, require_full_readiness: true)).to be(false)

      expect do
        EmployeeLinks::Invite.call(employee: incomplete_hire, actor: manager, delivery: "email")
      end.to raise_error(EmployeeLinks::Error, EmployeeLinks::InviteEligibility::INCOMPLETE_READINESS_MESSAGE)

      # Once Ready to pay, invite succeeds!
      incomplete_hire.update!(payment_delivery_method: "paper_check")
      EmployeeW4Election.create!(
        EmployeeW4Election::DEFAULT_PROFILE_ATTRIBUTES.except(:w4_effective_on).merge(
          company: company,
          employee: incomplete_hire,
          effective_on: Date.new(2026, 1, 1),
          w4_signed_on: Date.new(2026, 1, 1),
          w4_form_version: 2020,
          source: "client_direct",
          reason: "Signed W-4"
        )
      )

      result = EmployeeLinks::Invite.call(employee: incomplete_hire.reload, actor: manager, delivery: "email")
      expect(result.link).to be_persisted
      expect(result.link.status).to eq("invited")
    end
  end
end
