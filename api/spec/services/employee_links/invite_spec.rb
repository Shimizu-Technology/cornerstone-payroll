# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeLinks::Invite, type: :request do
  include EmployeeLinkHelpers

  let(:company) { create(:company) }
  let(:staff) { create(:user, role: :admin, company: company) }
  let(:employee) { create(:employee, company: company, email: "drew@example.net", date_of_birth: Date.new(1991, 3, 4)) }

  before { enable_employee_app!(company) }

  it "stays off while the company's employee app is off" do
    company.client_operating_profiles.sole.update_columns(employee_portal_enabled: false)

    expect { invite!(employee, actor: staff) }.to raise_error(EmployeeLinks::Error, /isn't turned on/)
    expect(EmployeeAccountLink.count).to eq(0)
  end

  it "refuses client users, staff without client configuration access, and staff outside the company" do
    outsider = create(:user, role: :admin)
    client = create(:user, role: :client, company: company)
    [ outsider, client ].each do |actor|
      expect { invite!(employee, actor: actor) }.to raise_error(EmployeeLinks::Forbidden)
    end
  end

  it "invites only active employees with no open link, and points a second invite at resend" do
    invite!(employee, actor: staff)
    expect { invite!(employee, actor: staff) }.to raise_error(EmployeeLinks::Error, /Resend it instead/)

    inactive = create(:employee, company: company, status: "inactive", email: "inactive@example.net")
    expect { invite!(inactive, actor: staff) }.to raise_error(EmployeeLinks::Error, /Only active employees/)
  end

  it "applies the M4-3 invite guard to email invites but not to printed codes" do
    create(:employee, company: company, email: "drew@example.net")
    expect { invite!(employee, actor: staff) }.to raise_error(EmployeeLinks::Error, /used by another employee/)

    employee.update_columns(email: nil)
    expect { invite!(employee, actor: staff) }.to raise_error(EmployeeLinks::Error, /required to send an email invite/)
    expect(invite!(employee, actor: staff, delivery: "code").code).to be_present
  end

  it "needs an employee app address for email invites" do
    ENV["EMPLOYEE_APP_URL"] = nil
    expect { invite!(employee, actor: staff) }.to raise_error(EmployeeLinks::Error, /address isn't set up/)
  end

  it "sends the invite only when portal email is on, with the token in the URL fragment" do
    expect(invite!(employee, actor: staff).email_status).to eq(:skipped)

    other = create(:employee, company: company, email: "kai@example.net")
    PortalNotifications::Transport.clear_captured!
    env = { "PORTAL_EMAIL_NOTIFICATIONS_ENABLED" => "true", "PORTAL_EMAIL_TRANSPORT" => "capture",
            "RESEND_FROM_EMAIL" => "payroll@example.test" }
    previous = env.keys.index_with { |key| ENV[key] }
    env.each { |key, value| ENV[key] = value }
    begin
      result = invite!(other, actor: staff)
    ensure
      previous.each { |key, value| ENV[key] = value }
    end

    expect(result.email_status).to eq(:captured)
    mail = PortalNotifications::Transport.captured.sole
    expect(mail).to include(to: "kai@example.net", subject: "You're invited to your employee app")
    expect(mail[:text]).to include("#{EmployeeLinkHelpers::APP_URL}/activate#token=#{CGI.escape(result.token)}")
    expect(mail[:text]).not_to match(/\$\d/)
  end

  it "keeps a pending employee app login out of staff Clerk-ID recovery" do
    pending_user = create(:user, role: :portal_employee, company: company, invitation_status: "pending", clerk_id: nil)
    platform_admin = create(:user, role: :super_admin, company: company)

    expect(PayrollInvitation.recoverable_by?(pending_user, platform_admin)).to be(false)
  end

  describe EmployeeLinks::Resend do
    it "rotates the token so the earlier invite stops working, keeps any lock, and audits" do
      first = invite!(employee, actor: staff)
      first.link.update_columns(failed_activation_attempts: 5, activation_locked_until: 1.day.from_now)

      resent = as_staff_in(company) { described_class.call(link: first.link, actor: staff) }

      expect(resent.link.id).to eq(first.link.id)
      expect(resent.token).not_to eq(first.token)
      expect(first.link.reload.invite_token_digest).to eq(EmployeeAccountLink.token_digest(resent.token))
      expect(first.link).to have_attributes(failed_activation_attempts: 5)
      expect(first.link.activation_locked_until).to be_future
      expect(link_audits(first.link, "invite_resent").count).to eq(1)

      first.link.update_columns(failed_activation_attempts: 0, activation_locked_until: nil)
      post_activation(activation_params(employee, token: first.token))
      expect(response).to have_http_status(:unprocessable_content)
      post_activation(activation_params(employee, token: resent.token))
      expect_sign_up_started
    end

    it "can switch an emailed invite to a printed code" do
      first = invite!(employee, actor: staff)
      resent = as_staff_in(company) { described_class.call(link: first.link, actor: staff, delivery: "code") }

      expect(first.link.reload).to have_attributes(invite_delivery: "code", invite_token_digest: nil, invite_email: nil)
      expect(first.link.invite_code_digest).to eq(EmployeeAccountLink.code_digest(resent.code))
    end

    it "refuses an active link" do
      link = invite!(employee, actor: staff).link
      link.update_columns(status: "active", user_id: create(:user, role: :portal_employee, company: company).id)

      expect { as_staff_in(company) { described_class.call(link: link, actor: staff) } }
        .to raise_error(EmployeeLinks::Error, /Only an open invite/)
    end
  end

  describe EmployeeLinks::Unlock do
    it "is staff only" do
      link = invite!(employee, actor: staff).link
      link.update_columns(failed_activation_attempts: 5, activation_locked_until: 1.day.from_now)
      client = create(:user, role: :client, company: company)

      expect { as_staff_in(company) { described_class.call(link: link, actor: client) } }.to raise_error(EmployeeLinks::Forbidden)
      expect(link.reload.failed_activation_attempts).to eq(5)
    end
  end
end
