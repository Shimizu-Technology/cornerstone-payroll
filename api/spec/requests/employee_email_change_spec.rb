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

  def notices
    EmployeeEmailChangeNotice.where(employee: employee).order(:id)
  end

  it "saves a pending notice to the old address with the change, then sends it after commit" do
    invite!(employee, actor: staff)

    expect { change_email(client, "riley.new@example.net") }.to have_enqueued_job(SendEmployeeEmailChangeNoticeJob)
    notice = notices.sole
    expect(notice).to have_attributes(recipient_email: "riley.old@example.net", status: "pending", company_id: company.id)
    expect(notice.change_id).to match(uuid_pattern)
    expect(SendEmployeeEmailChangeNoticeJob).to have_been_enqueued.with(notice.id)
  end

  it "keeps the notice when the queue is down, and the sweep sends it" do
    invite!(employee, actor: staff)
    allow(SendEmployeeEmailChangeNoticeJob).to receive(:perform_later).and_raise(StandardError, "queue down")

    change_email(client, "riley.new@example.net")
    expect(employee.reload.email).to eq("riley.new@example.net")
    expect(notices.sole.status).to eq("pending")

    allow(PortalNotifications).to receive(:delivery_enabled?).and_return(true)
    allow(PortalNotifications::Transport).to receive(:configured?).and_return(true)
    allow(PortalNotifications::Transport).to receive(:from_email).and_return("noreply@example.test")
    allow(PortalNotifications::Transport).to receive(:deliver).and_return("id" => "msg_1")
    SendEmployeeEmailChangeNoticeJob.new.perform
    expect(notices.sole).to have_attributes(status: "sent", attempts: 1)
  end

  it "still writes the employee update's own audit when the email and another field change together" do
    invite!(employee, actor: staff)
    patch "/api/v1/admin/employees/#{employee.id}", params: { employee: { email: "riley.new@example.net", job_title: "Lead Baker" } },
      as: :json, headers: bearer(staff.clerk_id).merge("X-Company-Id" => company.id.to_s)
    expect(response).to have_http_status(:ok), response.body

    expect(email_audit).to be_present
    expect(AuditLog.where(record_type: "employees", record_id: employee.id).where.not(action: "employee_links#contact_email_changed")
      .pluck(:action)).to include("employees#update")
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

    expect { change_email(staff, "riley.new@example.net") }.to have_enqueued_job(SendEmployeeEmailChangeNoticeJob)
    expect(notices.sole.recipient_email).to eq("riley.old@example.net")

    expect(login.reload.email).to eq("riley.old@example.net")
    expect(invite.link.reload).to have_attributes(status: "active", user_id: login.id)
    get "/api/v1/employee/context", headers: bearer("user_riley").merge("X-Employee-Link-Id" => invite.link.id.to_s)
    expect(response).to have_http_status(:ok)
    expect(email_audit.metadata["closed_invite_link_ids"]).to eq([])
  end

  it "applies the same safeguards when staff bulk-clear a shared placeholder email, from each row's original address" do
    employee.update_columns(email: "front.desk@example.net")
    other = create(:employee, company: company, first_name: "Avery", last_name: "Cruz", email: "front.desk@example.net",
      date_of_birth: Date.new(1988, 1, 2))
    invite = invite!(employee, actor: staff, delivery: "code")
    EmployeePlaceholderEmail.create!(organization: company.organization, email: "front.desk@example.net", marked_by: staff)
    generation = invite.link.invite_generation

    result = as_staff_in(company) do
      EmployeeContactHygiene::ClearSharedEmailService.new(company: company, email: "front.desk@example.net", actor: staff).call!
    end

    expect(result.cleared_count).to eq(2)
    expect([ employee.reload.email, other.reload.email ]).to eq([ nil, nil ])
    link = invite.link.reload
    expect(link).to have_attributes(invite_code_digest: nil, invite_generation: generation + 1)
    expect(link.invite_open?).to be(false)
    post_activation(activation_params(employee, code: invite.code, email: "anyone@example.net"))
    expect(response.parsed_body["code"]).to eq("activation_failed")

    expect(email_audit).to have_attributes(actor_type: "staff_user", user_id: staff.id)
    expect(email_audit.metadata).to include("from_email" => "front.desk@example.net", "closed_invite_link_ids" => [ link.id ])
    expect(notices.sole).to have_attributes(recipient_email: "front.desk@example.net", status: "pending")
    # The employee who never had app access gets no notice or app audit.
    expect(EmployeeEmailChangeNotice.where(employee: other)).to be_empty
  end

  describe "the notice" do
    before do
      allow(PortalNotifications).to receive(:delivery_enabled?).and_return(true)
      allow(PortalNotifications::Transport).to receive(:configured?).and_return(true)
      allow(PortalNotifications::Transport).to receive(:from_email).and_return("noreply@example.test")
    end

    let(:notice) do
      EmployeeEmailChangeNotice.create!(company: company, employee: employee, change_id: "change-a",
        recipient_email: "riley.old@example.net", status: "pending")
    end

    it "sends a short branded message naming the employer, and nothing else, to the old address" do
      sent = []
      allow(PortalNotifications::Transport).to receive(:deliver) { |payload, **options| sent << [ payload, options ]; { "id" => "msg_1" } }

      expect(SendEmployeeEmailChangeNoticeJob.new.perform(notice.id)).to eq(:sent)

      payload, options = sent.sole
      expect(payload).to include(to: "riley.old@example.net", subject: "The email for your Example Bakery employee app was changed",
        from: %("Example Bakery via Cornerstone Payroll" <noreply@example.test>))
      expect(payload[:text]).to include("The email for your Example Bakery employee app was changed",
        "If you made this change, you don't need to do anything. If you didn't, contact Example Bakery right away.")
      expect(payload[:html]).to include("<h1", "Example Bakery")
      expect(payload[:html]).not_to include("<a ")
      expect(options).to eq(idempotency_key: "employee-email-changed-change-a")
      expect(notice.reload).to have_attributes(status: "sent", attempts: 1)
      # Sent once: a repeat delivery does nothing.
      expect(SendEmployeeEmailChangeNoticeJob.new.perform(notice.id)).to eq(:skipped)
      expect(sent.size).to eq(1)
    end

    it "never puts the new address or a sign-in link in the notice" do
      invite = invite!(employee, actor: staff)
      sent = []
      allow(PortalNotifications::Transport).to receive(:deliver) { |payload, **_options| sent << payload; { "id" => "msg_1" } }

      change_email(client, "riley.new@example.net")
      SendEmployeeEmailChangeNoticeJob.new.perform(notices.sole.id)

      payload = sent.sole
      expect(payload[:to]).to eq("riley.old@example.net")
      body = payload.values_at(:subject, :text, :html).join
      expect(body).not_to include("riley.new")
      expect(body).not_to include(invite.token)
      expect(payload[:text]).not_to include("http")
      expect(payload[:html]).not_to include("href=")
    end

    it "sends a demo company's notice only through DemoOutbound, with a reply-to on the allow-list" do
      demo = create_demo_company(organization: company.organization, name: "Demo Bakery", fixture_key: "demo-bakery")
      demo.help_contacts.create!(position: 1, name: "Real person", email: "real.person@example.com")
      demo.help_contacts.create!(position: 2, name: "Demo desk", email: "desk@demo-mail.example")
      demo_employee = create(:employee, company: demo, email: "worker.old@demo-mail.example", date_of_birth: Date.new(1990, 1, 2))
      previous = ENV.fetch(DemoOutbound::ENV_KEY, nil)
      ENV[DemoOutbound::ENV_KEY] = "worker.old@demo-mail.example,desk@demo-mail.example"
      sent = []
      allow(PortalNotifications::Transport).to receive(:deliver).and_wrap_original do |_original, payload, **_options|
        sent << DemoOutbound.filter_payload(payload)
        { "id" => "msg_1" }
      end

      allowed = EmployeeEmailChangeNotice.create!(company: demo, employee: demo_employee, change_id: "change-demo",
        recipient_email: "worker.old@demo-mail.example", status: "pending")
      expect(EmployeeLinks::EmailChange.deliver_pending!(allowed.id)).to eq(:sent)
      expect(sent.sole).to include(to: [ "worker.old@demo-mail.example" ], reply_to: [ "desk@demo-mail.example" ])
      expect(sent.sole.values_at(:text, :html).join).not_to include("real.person")

      outside = EmployeeEmailChangeNotice.create!(company: demo, employee: demo_employee, change_id: "change-demo-2",
        recipient_email: "someone@example.net", status: "pending")
      expect(EmployeeLinks::EmailChange.deliver_pending!(outside.id)).to eq(:skipped)
      expect(sent.size).to eq(1)
    ensure
      ENV[DemoOutbound::ENV_KEY] = previous
    end

    it "gives each change its own notice, even two in the same second" do
      invite!(employee, actor: staff)

      freeze_time do
        change_email(client, "riley.new@example.net")
        change_email(client, "riley.newer@example.net")
      end

      expect(notices.pluck(:recipient_email)).to eq(%w[riley.old@example.net riley.new@example.net])
      expect(notices.pluck(:change_id).uniq.size).to eq(2)
      expect(notices.pluck(:change_id)).to all(match(uuid_pattern))
    end

    it "retries a failed send without the address in the error or the job's log" do
      allow(PortalNotifications::Transport).to receive(:deliver).and_raise(StandardError, "550 rejected riley.old@example.net")
      log = StringIO.new
      logger = ActiveSupport::TaggedLogging.new(Logger.new(log))
      allow(ActiveJob::Base).to receive(:logger).and_return(logger)
      allow(Rails).to receive(:logger).and_return(logger)

      expect { EmployeeLinks::EmailChange.deliver_pending!(notice.id) }
        .to raise_error(EmployeeLinks::EmailChange::DeliveryError) { |error| expect(error.message).not_to include("riley") }

      # The job's retry_on logs the error's message when it schedules the retry.
      expect { SendEmployeeEmailChangeNoticeJob.perform_now(notice.id) }.to have_enqueued_job(SendEmployeeEmailChangeNoticeJob)
      expect(log.string).to include("Retrying SendEmployeeEmailChangeNoticeJob", "EmployeeLinks::EmailChange::DeliveryError")
      expect(log.string).not_to include("riley.old@example.net")
      expect(notice.reload).to have_attributes(status: "failed", attempts: 2)
    end
  end
end
