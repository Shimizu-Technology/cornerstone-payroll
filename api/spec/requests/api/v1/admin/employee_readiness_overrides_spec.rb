# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee readiness override access", type: :request, portal_notifications: true do
  include EmployeeLinkHelpers
  include EmployeeLifecyclePr4Helpers
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, name: "Fictional Payroll Client") }
  let(:role) { "org_admin" }
  let(:delegated) { false }
  let(:actor) do
    create(:user, company: company, role: role, name: "Avery Reviewer", email: "avery@example.test",
      clerk_id: "user_readiness_reviewer", view_as_allowed: role == "super_admin")
  end
  let(:employee) { create_lifecycle_worker!(company) }
  let(:period) do
    create(:pay_period, company: company, start_date: Date.new(2026, 11, 1),
      end_date: Date.new(2026, 11, 14), pay_date: Date.new(2026, 11, 20))
  end
  let(:route) { "/api/v1/admin/employees/#{employee.id}" }
  let(:reason) { "Allow payment for the synthetic payroll test." }

  before do
    grantor = create(:user, company: company, role: "org_admin", name: "Riley Grantor", email: "grantor@example.test") if delegated
    create(:company_assignment, company: company, user: actor, client_management: delegated, granted_by: grantor)
  end

  def headers(age: 0, **claims)
    bearer(actor.clerk_id, fva: [ age, age ], two_factor_enabled: true, **claims).merge("X-Company-Id" => company.id.to_s)
  end

  def grant(request_headers: headers, **attrs)
    post "#{route}/readiness_override", headers: request_headers, params: {
      pay_period_id: period.id, default_w4_acknowledged: true, reason: reason
    }.merge(attrs), as: :json
  end

  def clear_gate(request_headers: headers)
    post "#{route}/clear_readiness_gate", headers: request_headers, params: { reason: reason }, as: :json
  end

  def revoke(override_id, request_headers: headers)
    delete "#{route}/readiness_override/#{override_id}", headers: request_headers, params: { reason: reason }, as: :json
  end

  it "keeps override and gate-clear writes dormant with the mode locked" do
    expect { grant }.not_to change(AdminOverride, :count)
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["code"]).to eq("client_lifecycle_disabled")
    clear_gate
    expect(response).to have_http_status(:forbidden)
    expect(employee.reload).to be_readiness_gate_enforced
  end

  context "when client-managed mode is enabled" do
    before do
      unlock_lifecycle_mode!
      create_client_managed_profile!(company)
    end

    [
      [ "accountant", false ], [ "accountant", true ], [ "manager", false ], [ "admin", false ], [ "client", false ]
    ].each do |candidate, delegation|
      context "as #{candidate}#{' with client_management' if delegation}" do
        let(:role) { candidate }
        let(:delegated) { delegation }

        it "refuses grant, revoke, and clear even after a fresh sign-in" do
          expect(StaffRolePolicy.allowed?(actor, :override_employee_readiness, company: company)).to be(false)
          grant
          expect(response).to have_http_status(:forbidden), response.body
          revoke(999_999)
          expect(response).to have_http_status(:forbidden)
          clear_gate
          expect(response).to have_http_status(:forbidden)
          expect(AdminOverride.where(company: company)).to be_empty
          expect(employee.reload).to be_readiness_gate_enforced
        end
      end
    end

    %w[org_admin super_admin].each do |candidate|
      context "as #{candidate}" do
        let(:role) { candidate }

        it "requires fresh step-up for grant, revoke, and clear and records each successful direct action" do
          stale = headers(age: 20)
          grant(request_headers: stale)
          expect(response).to have_http_status(:forbidden)
          expect(response.parsed_body.dig("clerk_error", "reason")).to eq("reverification-error")
          clear_gate(request_headers: stale)
          expect(response).to have_http_status(:forbidden)

          grant
          expect(response).to have_http_status(:created), response.body
          override = EmployeeReadinessOverride.find(response.parsed_body.dig("data", "id"))
          expect(override).to have_attributes(company: company, employee: employee, pay_period: period,
            granted_by: actor, default_w4_acknowledged: true, reason: reason)
          expect(override.admin_override).to have_attributes(actor: actor, subject: employee, reason: reason)
          expect(override.missing_items_snapshot).to eq([ "tax_form" ])
          expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: employee.reload)).to be_nil

          revoke(override.id, request_headers: stale)
          expect(response).to have_http_status(:forbidden)
          expect(override.reload.revoked_at).to be_nil
          revoke(override.id)
          expect(response).to have_http_status(:ok), response.body
          expect(override.reload).to have_attributes(revoked_by: actor, revoke_reason: reason)
          expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: employee.reload).missing_keys).to eq([ "tax_form" ])

          clear_gate
          expect(response).to have_http_status(:ok), response.body
          expect(employee.reload).not_to be_readiness_gate_enforced

          actions = %w[employee_readiness_override#grant employee_readiness_override#revoke employee_readiness_gate#clear]
          entries = AdminOverride.where(subject: employee).order(:id)
          expect(entries.pluck(:action)).to eq(actions)
          expect(AuditLog.where(company: company, action: actions).order(:id).pluck(:action)).to eq(actions)
          expect(PortalNotificationEvent.where(company: company, event_type: "admin_override").pluck(:dedupe_key))
            .to match_array(entries.flat_map { |entry| [ "admin_override:#{entry.id}:account_team", "admin_override:#{entry.id}:super_admins" ] })
        end
      end
    end

    context "inside a view-only support grant" do
      let(:role) { "super_admin" }

      it "denies every write despite a freshly verified real user" do
        grant
        expect(response).to have_http_status(:created), response.body
        override_id = response.parsed_body.dig("data", "id")
        client = create(:user, :with_client_assignment, company: company, role: "client",
          name: "Sloane Owner", email: "sloane@example.test")
        post "/api/v1/auth/view_as", headers: headers, params: {
          target_type: "client", target_id: client.id, reason: "Review the synthetic client experience."
        }, as: :json
        expect(response).to have_http_status(:created), response.body
        support_headers = headers.merge(ViewAsGrant::HEADER => response.parsed_body.fetch("token"))
        expect(ViewAsGrant.last).to be_open

        [ -> { grant(request_headers: support_headers) }, -> { revoke(override_id, request_headers: support_headers) },
          -> { clear_gate(request_headers: support_headers) } ].each do |write|
          write.call
          expect(response).to have_http_status(:forbidden)
          expect(response.parsed_body["code"]).to eq("view_as_read_only")
        end
        expect(employee.reload).to be_readiness_gate_enforced
        expect(EmployeeReadinessOverride.find(override_id).revoked_at).to be_nil
        expect(AdminOverride.where(subject: employee).count).to eq(1)
      end
    end

    it "validates scope, acknowledgement, and reason and prevents revoking after commit" do
      today = PayrollBusinessClock.today
      [
        { pay_period_id: nil }, { expires_on: (today + 7.days).iso8601 },
        { pay_period_id: nil, expires_on: (today + 31.days).iso8601 }, { pay_period_id: nil, expires_on: "later" },
        { reason: "short" }, { default_w4_acknowledged: false }
      ].each do |invalid|
        expect { grant(**invalid) }.not_to change(AdminOverride, :count)
        expect(response).to have_http_status(:unprocessable_content), response.body
      end
      expect(employee.employee_w4_elections).to be_empty

      grant
      expect(response).to have_http_status(:created), response.body
      override_id = response.parsed_body.dig("data", "id")
      ensure_verified_test_tax_years(2026)
      period.update!(status: "committed", committed_at: Time.current)
      revoke(override_id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(EmployeeReadinessOverride.find(override_id).revoked_at).to be_nil
    end

    it "bounds expiring coverage and fails closed on a newly missing checklist item" do
      expiry = PayrollBusinessClock.today + 3.days
      period.update!(pay_date: expiry)
      grant(pay_period_id: nil, expires_on: expiry.iso8601)
      expect(response).to have_http_status(:created), response.body
      override = EmployeeReadinessOverride.find(response.parsed_body.dig("data", "id"))
      expect(override).to have_attributes(pay_period_id: nil, expires_on: expiry)
      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: employee.reload)).to be_nil
      employee.update!(payment_delivery_method: nil)
      expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: employee.reload).missing_keys)
        .to contain_exactly("payment_method", "tax_form")
      employee.update!(payment_delivery_method: "paper_check")
      travel_to((expiry + 1.day).in_time_zone(PayrollBusinessClock::TIME_ZONE).noon) do
        expect(PayrollReadinessPolicy.readiness_blocker_for(pay_period: period, employee: employee.reload).missing_keys).to eq([ "tax_form" ])
      end
    end

    it "rejects another tenant's pay period and rolls back the grant if its audit fails" do
      different_company_period = create(:pay_period)
      grant(pay_period_id: different_company_period.id)
      expect(response).to have_http_status(:not_found)

      allow(AuditLog).to receive(:record!).and_call_original
      allow(AuditLog).to receive(:record!).with(hash_including(action: "employee_readiness_override#grant"))
        .and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))
      grant
      expect(response).to have_http_status(:unprocessable_content)
      expect(AdminOverride.where(company: company)).to be_empty
      expect(employee.employee_w4_elections).to be_empty
      expect(employee.employee_readiness_overrides).to be_empty
      expect(PortalNotificationEvent.where(company: company, event_type: "admin_override")).to be_empty
    end

    it "refuses the legacy intake exception review for a gated worker" do
      employee.update!(intake_exception: { "reason" => "Synthetic intake exception" })
      manager = create(:user, company: company, role: "manager", name: "Morgan Staff", email: "morgan@example.test")
      create(:company_assignment, company: company, user: manager)
      expect do
        EmployeeIntakeExceptionReviewService.call!(employee: employee, actor: manager, attributes: {
          confirm_payroll_setup: true, reason: reason, acknowledge_default_withholding: true
        })
      end.to raise_error(EmployeeIntakeExceptionReviewService::Error, /readiness checklist/)
      expect(employee.reload.intake_payroll_confirmed_at).to be_nil
      expect(employee.employee_w4_elections).to be_empty
    end
  end
end
