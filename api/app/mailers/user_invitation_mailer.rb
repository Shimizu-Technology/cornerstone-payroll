# frozen_string_literal: true

class UserInvitationMailer < ApplicationMailer
  default from: "no-reply@cornerstone-payroll.com"

  def invite_email(invitation, invite_url)
    @invitation = invitation
    @invite_url = invite_url

    from_email = ENV.fetch("MAILER_FROM_EMAIL", "no-reply@cornerstone-payroll.com")
    return unless ENV["RESEND_API_KEY"].present?

    Resend::Emails.send(
      from: from_email,
      to: invitation.email,
      subject: "You're invited to Cornerstone Payroll",
      html: render_to_string("user_invitation_mailer/invite_email", formats: [ :html ]),
      text: render_to_string("user_invitation_mailer/invite_email", formats: [ :text ])
    )
  end
end
