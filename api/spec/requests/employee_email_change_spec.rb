# frozen_string_literal: true

require "rails_helper"

# The employer is the source of truth for an employee's email, so a client or
# staff edit is never blocked. EmployeeLinks::EmailChange closes an open
# invite, audits who changed it and tells the old address.
RSpec.describe "Employee email changes and the employee app", type: :request do
  include EmployeeLinkHelpers

  let(:company) { create(:company, name: "Example Bakery") }
  let(:staff) { create(:user, role: :admin, company: company, clerk_id: "user_email_staff") }
  let(:client) do
    create(:user, role: :client, company: company, clerk_id: "user_email_client").tap do |user|
      CompanyAssignment.create!(user: user, company: company)
    end
  end
  let(:employee) do
    create(:employee, company: company, first_name: "Riley", last_name: "Santos", email: "riley.old@example.net",
      date_of_birth: Date.new(1990, 4, 12))
  end

  include ActiveSupport::Testing::TimeHelpers

  let(:uuid_pattern) { /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/ }

  before { enable_employee_app!(company) }

  def change_email(actor, email)
    namespace = actor.client? ? "client" : "admin"
    patch "/api/v1/#{namespace}/employees/#{employee.id}", params: { employee: { email: email } }, as: :json,
      headers: bearer(actor.clerk_id).merge("X-Company-Id" => company.id.to_s)
    expect(response).to have_http_status(:ok), response.body
  end

  def email_audit
    AuditLog.where(action: "employee_links#contact_email_changed", record_type: "employees", record_id: employee.id).sole
  end

  %i[client staff].each do |who|
    it "closes an open invite when #{who} changes the email, so the old invite can't be used" do
      actor = public_send(who)
      invite = invite!(employee, actor: staff)
      generation = invite.link.invite_generation

      change_email(actor, "riley.new@example.net")

      link = invite.link.reload
      expect(link).to have_attributes(status: "invited", invite_token_digest: nil, invite_code_digest: nil,
        invite_generation: generation + 1)
      expect(link.invite_open?).to be(false)
      expect(link_audits(link, "invite_closed_by_email_change").sole.actor_type).to eq(actor.client? ? "client_user" : "staff_user")

      post_activation(activation_params(employee.reload, email: "riley.old@example.net", token: invite.token))
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["code"]).to eq("activation_failed")

      # A resend goes to the new address on file.
      resent = as_staff_in(company) { EmployeeLinks::Resend.call(link: link, actor: staff, delivery: "email") }
      expect(resent.link.invite_email).to eq("riley.new@example.net")
    end

    it "audits who changed the email (#{who}) with both addresses" do
      actor = public_send(who)
      invite!(employee, actor: staff)

      change_email(actor, "riley.new@example.net")

      expect(email_audit).to have_attributes(actor_type: actor.client? ? "client_user" : "staff_user",
        user_id: actor.id, company_id: company.id, event_category: "security")
      expect(email_audit.metadata).to include("from_email" => "riley.old@example.net", "to_email" => "riley.new@example.net")
    end
  end

  it "closes a Clerk sign-up started for the invite, so it can't bind after the change" do
    invite = invite!(employee, actor: staff)
    post_activation(activation_params(employee, token: invite.token))
    expect_sign_up_started
    accept_clerk_invitation!("user_riley")

    change_email(client, "riley.new@example.net")

    get "/api/v1/auth/me", headers: bearer("user_riley")
    expect(response).to have_http_status(:unauthorized)
    expect(invite.link.reload).to be_invited
  end

  it "tells the old address about the change when the person has an invite or an active or former link" do
    invite!(employee, actor: staff)

    expect { change_email(client, "riley.new@example.net") }
      .to have_enqueued_job(SendEmployeeEmailChangeNoticeJob).with(employee.id, "riley.old@example.net", match(uuid_pattern))
  end

  it "doesn't notify or audit for an employee who never had employee app access" do
    expect { change_email(client, "riley.new@example.net") }.not_to have_enqueued_job(SendEmployeeEmailChangeNoticeJob)
    expect(AuditLog.where(action: "employee_links#contact_email_changed")).to be_empty
  end

  it "never changes an active link's sign-in, and the old address hears about it" do
    invite = invite!(employee, actor: staff)
    post_activation(activation_params(employee, token: invite.token))
    accept_clerk_invitation!("user_riley")
    get "/api/v1/auth/me", headers: bearer("user_riley")
    login = invite.link.reload.user
    expect(invite.link).to be_active

    expect { change_email(staff, "riley.new@example.net") }
      .to have_enqueued_job(SendEmployeeEmailChangeNoticeJob).with(employee.id, "riley.old@example.net", match(uuid_pattern))

    expect(login.reload.email).to eq("riley.old@example.net")
    expect(invite.link.reload).to have_attributes(status: "active", user_id: login.id)
    get "/api/v1/employee/context", headers: bearer("user_riley").merge("X-Employee-Link-Id" => invite.link.id.to_s)
    expect(response).to have_http_status(:ok)
    expect(email_audit.metadata["closed_invite_link_ids"]).to eq([])
  end

  describe "the notice" do
    before do
      allow(PortalNotifications).to receive(:delivery_enabled?).and_return(true)
      allow(PortalNotifications::Transport).to receive(:configured?).and_return(true)
      allow(PortalNotifications::Transport).to receive(:from_email).and_return("noreply@example.test")
    end

    it "sends a short message naming the employer, and nothing else, to the old address" do
      sent = []
      allow(PortalNotifications::Transport).to receive(:deliver) { |payload, **options| sent << [ payload, options ]; { "id" => "msg_1" } }

      expect(SendEmployeeEmailChangeNoticeJob.new.perform(employee.id, "riley.old@example.net", "change-a")).to eq(:sent)

      payload, options = sent.sole
      expect(payload).to include(to: "riley.old@example.net", subject: "The email for your Example Bakery employee app was changed",
        text: "The email for your Example Bakery employee app was changed. If you didn't expect this, contact Example Bakery.")
      expect(options).to eq(idempotency_key: "employee-email-changed-change-a")
    end

    it "gives each change its own notice, even two in the same second" do
      invite!(employee, actor: staff)
      ids = []
      allow(SendEmployeeEmailChangeNoticeJob).to receive(:perform_later) { |*args| ids << args.last }

      freeze_time do
        change_email(client, "riley.new@example.net")
        change_email(client, "riley.newer@example.net")
      end

      expect(ids.size).to eq(2)
      expect(ids.uniq.size).to eq(2)
      expect(ids).to all(match(uuid_pattern))
    end

    it "keeps the address out of the job's log lines" do
      expect(SendEmployeeEmailChangeNoticeJob.log_arguments?).to be(false)
    end
  end
end
