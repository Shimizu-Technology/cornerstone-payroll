# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Employee app rollout administration", type: :request do
  include EmployeeLinkHelpers

  let(:company) { create(:company, name: "Example Bakery") }
  let(:other_company) { create(:company, organization: company.organization, name: "Example Bookshop") }
  let(:staff) { create(:user, company: company, role: :admin, clerk_id: "user_rollout_staff") }
  let(:client) do
    create(:user, company: company, role: :client, clerk_id: "user_rollout_client").tap do |user|
      CompanyAssignment.create!(user: user, company: company)
    end
  end
  let(:outsider) do
    create(:user, company: other_company, role: :client, clerk_id: "user_rollout_outsider").tap do |user|
      CompanyAssignment.create!(user: user, company: other_company)
    end
  end
  let(:employee) do
    create(:employee, company: company, first_name: "Sample", last_name: "Worker",
      email: "worker@example.test", phone: "671-555-0101", date_of_birth: Date.new(1991, 1, 2))
  end

  def rollout_path(actor, target: company)
    "/api/v1/#{actor.client? ? 'client' : 'admin'}/employee_app_rollout/#{target.id}"
  end

  def panel_path(actor)
    "/api/v1/#{actor.client? ? 'client' : 'admin'}/employees/#{employee.id}/employee_app"
  end

  def headers(actor, target: actor.company)
    bearer(actor.clerk_id).merge("X-Company-Id" => target.id.to_s)
  end

  def mutate(actor, action, target: actor.company, **payload)
    post "#{panel_path(actor)}/#{action}", headers: headers(actor, target: target), params: payload, as: :json
  end

  def invite_wave(actor, ids, delivery: "code", target: actor.company)
    post "#{rollout_path(actor, target: target)}/invite", headers: headers(actor, target: target),
      params: { employee_ids: ids, delivery: delivery }, as: :json
  end

  def get_panel(actor)
    get panel_path(actor), headers: headers(actor)
  end

  def data
    response.parsed_body.fetch("data")
  end

  it "shows both screens while off and refuses single and wave invites" do
    [ staff, client ].each do |actor|
      get_panel(actor)
      expect(response).to have_http_status(:ok)
      expect(data).to include("enabled" => false, "status" => "not_invited")

      get rollout_path(actor), headers: headers(actor)
      expect(response).to have_http_status(:ok)
      expect(data).to include("enabled" => false)
      expect(data["counts"]["ready_to_invite"]).to eq(1)

      mutate(actor, "invite", delivery: "code")
      expect(response).to have_http_status(:unprocessable_content)

      post "#{rollout_path(actor)}/invite", headers: headers(actor), params: { employee_ids: [ employee.id ], delivery: "email" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
    end
    expect(employee.employee_account_links).to be_empty
  end

  context "with a fictional enabled company" do
    before { enable_employee_app!(company) }

    it "lets staff invite and resend with one-time printed codes and audited delivery" do
      mutate(staff, "invite", delivery: "code")

      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("no-store")
      first_code = response.parsed_body.dig("print", "code")
      expect(first_code.length).to eq(10)
      expect(response.parsed_body.dig("print", "url")).to eq("#{EmployeeLinkHelpers::APP_URL}/activate")
      expect(data).to include("status" => "invited", "staff_actions" => staff.staff_member?)

      access = employee.employee_account_links.sole
      expect(access.invite_code_digest).to eq(EmployeeAccountLink.code_digest(first_code))
      expect(link_audits(access, "invited").sole).to have_attributes(user_id: staff.id, company_id: company.id)
      expect(link_audits(access, "invited").sole.metadata).to include("delivery" => "code")

      get_panel(staff)
      expect(response.body).not_to include(first_code, "invite_code_digest")
      expect(response.parsed_body).not_to have_key("print")

      mutate(staff, "resend", access_id: access.id, delivery: "code")
      expect(response).to have_http_status(:ok)
      next_code = response.parsed_body.dig("print", "code")
      expect(next_code).not_to eq(first_code)
      expect(access.reload.invite_code_digest).to eq(EmployeeAccountLink.code_digest(next_code))
      audit = link_audits(access, "invite_resent").sole
      expect(audit.user_id).to eq(staff.id)
      expect(audit.metadata.to_json).not_to include(first_code, next_code)
    end

    it "refuses every printed-code request from a client manager with a plain 403, even past the UI" do
      no_email = create(:employee, company: company, email: nil)
      get rollout_path(client), headers: headers(client)
      expect(data).to include("can_manage_invites" => true, "can_print_codes" => false)
      get_panel(client)
      expect(data).to include("can_print_codes" => false, "staff_actions" => false)

      mutate(client, "invite", delivery: "code")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => EmployeeLinks::STAFF_CODES_ONLY)

      invite_wave(client, [ employee.id, no_email.id ], delivery: "code")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => EmployeeLinks::STAFF_CODES_ONLY)
      expect(EmployeeAccountLink.where(company: company)).to be_empty

      # Reprinting or resetting a code staff already printed.
      access = invite!(employee, actor: staff, delivery: "code").link
      mutate(client, "resend", access_id: access.id, delivery: "code")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body).to eq("error" => EmployeeLinks::STAFF_CODES_ONLY)
      mutate(client, "reset_sign_up", access_id: access.id, delivery: "code", reason: "Lost the paper")
      expect(response).to have_http_status(:forbidden)
      expect(access.reload).to have_attributes(invite_generation: 1, invited_by_id: staff.id)
      expect(AuditLog.where(record_type: EmployeeLinks::AUDIT_RECORD_TYPE, user_id: client.id)).to be_empty

      # The services refuse too, whatever calls them.
      expect { invite!(no_email, actor: client, delivery: "code") }
        .to raise_error(EmployeeLinks::Forbidden, EmployeeLinks::STAFF_CODES_ONLY)
      expect { as_staff_in(company) { EmployeeLinks::Resend.call(link: access, actor: client, delivery: "code") } }
        .to raise_error(EmployeeLinks::Forbidden, EmployeeLinks::STAFF_CODES_ONLY)

      get rollout_path(staff), headers: headers(staff)
      expect(data).to include("can_print_codes" => true)
    end

    it "sends a client's email invite only to the address on file" do
      allow(EmployeeLinks::InviteEmail).to receive(:deliver).and_return(:sent)

      mutate(client, "invite", delivery: "email", email: "someone.else@example.test")
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to eq(EmployeeAppRolloutActions::EMAIL_ON_FILE_ONLY)
      post "#{rollout_path(client)}/invite", headers: headers(client),
        params: { employee_ids: [ employee.id ], delivery: "email", email: "someone.else@example.test" }, as: :json
      expect(response).to have_http_status(:unprocessable_content)
      expect(employee.employee_account_links).to be_empty
      expect(EmployeeLinks::InviteEmail).not_to have_received(:deliver)

      mutate(client, "invite", delivery: "email", email: "Worker@Example.test")
      expect(response).to have_http_status(:ok)
      expect(employee.employee_account_links.sole.invite_email).to eq("worker@example.test")
      expect(EmployeeLinks::InviteEmail).to have_received(:deliver).once
    end

    %i[staff client].each do |who|

      it "lets #{who} send email and reports the delivery result without returning the secret" do
        actor = public_send(who)
        allow(EmployeeLinks::InviteEmail).to receive(:deliver).and_return(:sent)
        mutate(actor, "invite", delivery: "email")

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.keys).to match_array(%w[data email_status])
        expect(response.parsed_body["email_status"]).to eq("sent")
        access = employee.employee_account_links.sole
        expect(link_audits(access, "invited").sole.metadata).to include("delivery" => "email")
        expect(access.invite_email).to eq(employee.email)

        allow(EmployeeLinks::InviteEmail).to receive(:deliver).and_return(:failed)
        mutate(actor, "resend", access_id: access.id, delivery: "email")
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["email_status"]).to eq("failed")
        expect(link_audits(access, "invite_resent").sole.user_id).to eq(actor.id)
      end

      it "lets #{who} invite a wave and reports unavailable and undelivered rows individually" do
        actor = public_send(who)
        no_email = create(:employee, company: company, email: nil)
        other = create(:employee, company: other_company)
        allow(EmployeeLinks::InviteEmail).to receive(:deliver).and_return(:failed)
        post "#{rollout_path(actor)}/invite", headers: headers(actor),
          params: { employee_ids: [ other.id, employee.id, no_email.id, employee.id ], delivery: "email" }, as: :json

        expect(response).to have_http_status(:ok)
        expect(data).to eq([
          { "id" => other.id, "error" => "Employee not found in this company." },
          { "id" => employee.id, "email_status" => "failed" },
          { "id" => no_email.id, "error" => "Email is required to send an email invite" }
        ])
        expect(link_audits(employee.employee_account_links.sole, "invited").sole.user_id).to eq(actor.id)
        expect(other.employee_account_links).to be_empty

        post "#{rollout_path(actor)}/invite", headers: headers(actor),
          params: { employee_ids: [ no_email.id ], delivery: "code" }, as: :json
        if actor.staff_member?
          expect(response).to have_http_status(:ok)
          expect(data.sole.dig("print", "code").length).to eq(10)
          expect(link_audits(no_email.employee_account_links.sole, "invited").sole.user_id).to eq(actor.id)
        else
          expect(response).to have_http_status(:forbidden)
          expect(no_email.employee_account_links).to be_empty
        end
      end
    end

    it "gives an assigned accountant without Client management read-only rollout access" do
      accountant = create(:user, company: other_company, role: :accountant, clerk_id: "user_rollout_accountant")
      create(:company_assignment, user: accountant, company: company, client_management: false)

      get rollout_path(accountant), headers: headers(accountant, target: company)
      expect(response).to have_http_status(:ok)
      expect(data).to include("enabled" => true, "can_manage_invites" => false)

      mutate(accountant, "invite", target: company, delivery: "code")
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq(StaffRolePolicy.error_message(:manage_client_configuration))
      invite_wave(accountant, [ employee.id ], target: company)
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]).to eq(StaffRolePolicy.error_message(:manage_client_configuration))
      expect(employee.employee_account_links).to be_empty
    end

    it "rejects empty, oversized, or malformed waves before inviting any employee" do
      invalid_waves = [ [], Array.new(26, employee.id), [ employee.id, "2x" ], [ employee.id, 0 ],
        [ employee.id, -1 ], [ employee.id, "9223372036854775808" ], [ employee.id, { id: employee.id } ] ]
      invalid_waves.each do |ids|
        invite_wave(staff, ids)
        expect(response).to have_http_status(:unprocessable_content), ids.inspect
        expect(response.parsed_body["error"]).to eq("Select between 1 and 25 employees.")
      end
      expect(employee.employee_account_links).to be_empty
    end

    it "keeps the original credential when a later wave includes an already-invited employee" do
      invite_wave(staff, [ employee.id ])
      expect(response).to have_http_status(:ok)
      first_code = data.sole.fetch("print").fetch("code")
      access = employee.employee_account_links.sole
      next_employee = create(:employee, company: company)

      invite_wave(staff, [ employee.id, next_employee.id ])
      expect(response).to have_http_status(:ok)
      expect(data.first).to eq("id" => employee.id, "error" => "This employee already has an invite. Resend it instead.")
      expect(data.last).to include("id" => next_employee.id, "print" => include("code" => be_present))
      expect(employee.employee_account_links.reload.sole).to have_attributes(id: access.id, invite_generation: 1,
        invite_code_digest: EmployeeAccountLink.code_digest(first_code))
      expect(link_audits(access, "invited").size).to eq(1)
    end

    context "with outbound email restricted to demo recipients" do
      let(:company) { create_demo_company(organization: create(:organization)) }

      it "reports a DemoOutbound refusal for the row and continues checking the wave" do
        # Demo workspaces normally keep the app off. Open only that feature gate
        # to exercise the delivery guard behind it.
        allow_any_instance_of(CompanyFeatures).to receive(:employee_portal_enabled?).and_return(true)
        other = create(:employee, company: other_company)
        allow(DemoOutbound).to receive(:allowlist).and_return(Set.new)
        allow(DemoOutbound).to receive(:permit?).and_call_original
        allow(EmployeeLinks::InviteEmail).to receive(:deliver).and_return(:sent)

        invite_wave(staff, [ employee.id, other.id ], delivery: "email")

        expect(response).to have_http_status(:ok), response.body
        expect(data).to eq([
          { "id" => employee.id, "error" => Company::DEMO_RECIPIENT_REFUSED_MESSAGE },
          { "id" => other.id, "error" => "Employee not found in this company." }
        ])
        expect(DemoOutbound).to have_received(:permit?).with(company: company, email: employee.email, channel: "employee_link_invite")
        expect(employee.employee_account_links).to be_empty
        expect(EmployeeLinks::InviteEmail).not_to have_received(:deliver)
      end
    end

    it "refuses to resend or reset an existing invitation after the app is turned off" do
      access = invite!(employee, actor: staff, delivery: "code").link
      company.client_operating_profiles.sole.update_columns(employee_portal_enabled: false)

      mutate(client, "resend", access_id: access.id, delivery: "code")
      expect(response).to have_http_status(:unprocessable_content)
      mutate(staff, "reset_sign_up", access_id: access.id, delivery: "code", reason: "Test reason")
      expect(response).to have_http_status(:unprocessable_content)
      expect(access.reload).to have_attributes(status: "invited", invite_generation: 1)
      expect(link_audits(access, "invite_resent")).to be_empty
      expect(link_audits(access, "sign_up_reset_started")).to be_empty
    end

    it "returns 404 for another company's employee and rollout" do
      access = invite!(employee, actor: staff, delivery: "code").link
      get_panel(outsider)
      expect(response).to have_http_status(:not_found)
      %w[invite resend unlock revoke reset_sign_up].each do |action|
        mutate(outsider, action, access_id: access.id, delivery: "code", reason: "Test reason")
        expect(response).to have_http_status(:not_found), action
      end
      get rollout_path(outsider), headers: headers(outsider)
      expect(response).to have_http_status(:not_found)
      post "#{rollout_path(outsider)}/invite", headers: headers(outsider),
        params: { employee_ids: [ employee.id ], delivery: "code" }, as: :json
      expect(response).to have_http_status(:not_found)
      expect(access.reload).to be_invited
    end

    it "refuses staff-only actions for an otherwise authorized client" do
      access = invite!(employee, actor: staff, delivery: "code").link
      %w[unlock revoke reset_sign_up].each do |action|
        mutate(client, action, access_id: access.id, delivery: "code", reason: "Test reason")
        expect(response).to have_http_status(:forbidden), action
      end
      expect(access.reload).to have_attributes(status: "invited", invite_generation: 1)
      expect(AuditLog.where(record_type: EmployeeLinks::AUDIT_RECORD_TYPE, user_id: client.id)).to be_empty
    end

    it "unlocks and revokes through their staff services" do
      access = invite!(employee, actor: staff, delivery: "code").link
      access.update!(failed_activation_attempts: 5, activation_locked_at: Time.current, activation_locked_until: 24.hours.from_now)
      get_panel(staff)
      expect(data["status"]).to eq("locked")

      mutate(staff, "unlock", access_id: access.id)
      expect(response).to have_http_status(:ok)
      expect(data["status"]).to eq("invited")
      audit = link_audits(access, "activation_unlocked").sole
      expect(audit.user_id).to eq(staff.id)
      expect(audit.metadata).to include("failed_attempts_cleared" => 5)

      mutate(staff, "revoke", access_id: access.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(access.reload).to be_invited
      mutate(staff, "revoke", access_id: access.id, reason: "Access ended at employee request")
      expect(response).to have_http_status(:ok)
      expect(data["status"]).to eq("revoked")
      audit = link_audits(access, "revoked").sole
      expect(audit.user_id).to eq(staff.id)
      expect(audit.metadata).to include("reason" => "Access ended at employee request")
    end

    it "shows an accepted sign-up result to the client without rotating the invite" do
      issued = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: issued.code))
      expect_sign_up_started
      accept_clerk_invitation!("user_accepted_test")

      mutate(client, "resend", access_id: issued.link.id, delivery: "email")
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "sign_up_accepted", "error" => EmployeeLinks::Resend::ACCEPTED)
      expect(issued.link.reload.invite_generation).to eq(1)
      expect(link_audits(issued.link, "invite_resent")).to be_empty
    end

    it "gives clients and staff different next steps for an accepted sign-up that can no longer finish" do
      issued = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: issued.code))
      expect_sign_up_started
      accept_clerk_invitation!("user_stale_rollout")
      issued.link.update!(invite_expires_at: 1.minute.ago)

      mutate(client, "resend", access_id: issued.link.id, delivery: "email")
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "sign_up_accepted",
        "error" => "This person already created their account, but that sign-up can no longer finish. Ask Cornerstone to reset it.")

      mutate(staff, "resend", access_id: issued.link.id, delivery: "code")
      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body).to include("code" => "sign_up_accepted", "error" => EmployeeLinks::Resend::ACCEPTED_STALE)
      expect(issued.link.reload.invite_generation).to eq(1)
      expect(link_audits(issued.link, "invite_resent")).to be_empty
    end

    it "shows a failed staff reset as pending and audits a successful retry with a fresh code" do
      issued = invite!(employee, actor: staff, delivery: "code")
      post_activation(activation_params(employee, code: issued.code))
      expect_sign_up_started

      mutate(staff, "reset_sign_up", access_id: issued.link.id, delivery: "code")
      expect(response).to have_http_status(:unprocessable_content)
      expect(link_audits(issued.link, "sign_up_reset_started")).to be_empty

      allow(clerk).to receive(:revoke_invitation).and_return(success: false, status: 503)
      mutate(staff, "reset_sign_up", access_id: issued.link.id, delivery: "code", reason: "Unfinished sign-up")
      expect(response).to have_http_status(:unprocessable_content)
      get_panel(staff)
      expect(data["reset_pending"]).to be true
      expect(issued.link.reload.invite_code_digest).to be_nil

      get rollout_path(staff), headers: headers(staff)
      expect(data.dig("todo", "reset_pending")).to eq([ { "id" => employee.id, "name" => employee.display_name } ])
      expect(data.dig("todo", "expiring")).to be_empty
      get rollout_path(client), headers: headers(client)
      expect(data.dig("todo", "reset_pending")).to be_empty

      allow(clerk).to receive(:revoke_invitation).and_return(success: true)
      mutate(staff, "reset_sign_up", access_id: issued.link.id, delivery: "code", reason: "Unfinished sign-up")
      expect(response).to have_http_status(:ok)
      expect(data["reset_pending"]).to be false
      next_code = response.parsed_body.dig("print", "code")
      expect(next_code).not_to eq(issued.code)
      expect(issued.link.reload.invite_code_digest).to eq(EmployeeAccountLink.code_digest(next_code))

      %w[sign_up_reset_started sign_up_reset_resumed sign_up_reset].each do |action|
        audit = link_audits(issued.link, action).sole
        expect(audit.user_id).to eq(staff.id)
        expect(audit.metadata["reason"]).to eq("Unfinished sign-up")
      end

      get rollout_path(staff), headers: headers(staff)
      expect(data.dig("todo", "reset_pending")).to be_empty
    end

    it "keeps expired, unswept invitations in the to-do list alongside upcoming expirations" do
      expired = invite!(employee, actor: staff, delivery: "code").link
      expired.update!(invite_expires_at: 1.minute.ago)
      expiring = create(:employee, company: company)
      invite!(expiring, actor: staff, delivery: "code").link.update!(invite_expires_at: 2.days.from_now)
      invite!(create(:employee, company: company), actor: staff, delivery: "code")

      get rollout_path(client), headers: headers(client)
      expect(response).to have_http_status(:ok)
      expect(data.dig("todo", "expiring")).to contain_exactly(
        include("id" => employee.id, "expired" => true), include("id" => expiring.id, "expired" => false)
      )
      expect(expired.reload).to be_invited
    end

    it "keeps client-submitted new hires awaiting approval out of termination cleanup" do
      cleanup = create(:employee, company: company, status: "inactive")
      create(:employee, company: company, status: "inactive", portal_pending_approval: true, pay_rate: 0)

      get rollout_path(staff), headers: headers(staff)
      expect(response).to have_http_status(:ok)
      expect(data.dig("todo", "cleanup").pluck("id")).to eq([ cleanup.id ])
    end

    it "requires employees sharing their payroll login email to be invited by email from their record" do
      client.update!(email: employee.email, name: employee.display_name)
      ready = create(:employee, company: company, email: "another.worker@example.test", phone: "671-555-0103")

      [ staff, client ].each do |actor|
        get rollout_path(actor), headers: headers(actor)
        expect(response).to have_http_status(:ok)
        expect(data.dig("counts", "ready_to_invite")).to eq(1)
        expect(data["candidates"]).to contain_exactly(
          include("id" => employee.id, "email_ready" => false, "email_review_required" => true),
          include("id" => ready.id, "email_ready" => true, "email_review_required" => false)
        )
      end

      invite_wave(client, [ employee.id ], delivery: "email")
      expect(response).to have_http_status(:ok)
      expect(data.sole).to include("id" => employee.id, "error" => include('Confirm "this is me"'))
      expect(employee.employee_account_links).to be_empty

      mutate(client, "invite", delivery: "email", confirm_same_person_email: true)
      expect(response).to have_http_status(:ok)
      expect(employee.employee_account_links.sole.claim_user).to eq(client)
    end

    it "counts current access, shows cleanup and pending work, and uses the existing lock alert" do
      locked = invite!(employee, actor: staff, delivery: "code").link
      locked.update!(failed_activation_attempts: 5, activation_locked_at: Time.current, activation_locked_until: 23.hours.from_now)
      as_staff_in(company) do
        AuditLog.record!(organization_id: company.organization_id, company_id: company.id, actor: EmployeeLinks.verifier_actor,
          record_type: "companies", record_id: company.id, action: "employee_links#activation_lock_alert")
      end
      expiring = create(:employee, company: company, email: nil)
      invite!(expiring, actor: staff, delivery: "code").link.update!(invite_expires_at: 2.days.from_now)
      cleanup = create(:employee, company: company, status: "inactive")
      ready = create(:employee, company: company, email: "ready@example.test", phone: "671-555-0102")
      former = create(:employee, company: company, status: "terminated", termination_date: Date.new(2026, 10, 1))
      active = create(:employee, company: company, email: "active@example.test", phone: "671-555-0103")
      ends = 1.year.from_now
      EmployeeAccountLink.create!(company: company, employee: former, user: client, status: "former", former_access_until: ends)
      EmployeeAccountLink.create!(company: company, employee: active, user: client, status: "active")

      get rollout_path(client), headers: headers(client)
      expect(response).to have_http_status(:ok)
      expect(data["counts"]).to eq("ready_to_invite" => 1, "invited" => 1, "active" => 1,
        "needs_contact_details" => 1, "locked" => 1, "former" => 1)
      expect(data["candidates"].pluck("id")).to eq([ ready.id ])
      expect(data.dig("todo", "locked").pluck("id")).to eq([ employee.id ])
      expect(data.dig("todo", "expiring").pluck("id")).to eq([ expiring.id ])
      expect(data.dig("todo", "needs_contact_details").pluck("id")).to eq([ expiring.id ])
      expect(data.dig("todo", "cleanup").pluck("id")).to eq([ cleanup.id ])
      expect(data["lock_alert"]).to be_present

      get "/api/v1/client/employees/#{former.id}/employee_app", headers: headers(client)
      expect(response).to have_http_status(:ok)
      expect(data).to include("status" => "former")
      expect(Time.iso8601(data["former_access_until"])).to be_within(1.second).of(ends)
    end
  end
end
