# frozen_string_literal: true

module EmployeeLinks
  # Keeps the link and rotates its token or code, so an earlier email or
  # printed code stops working, with a fresh 14-day expiry. A lock stays in
  # place until staff unlock it.
  class Resend
    def self.call(...)
      new(...).call
    end

    def initialize(link:, actor:, delivery: nil, confirm_same_person_email: false, request: nil)
      @link = link
      @actor = actor
      @delivery = (delivery.presence || link.invite_delivery || "email").to_s
      @confirm_same_person_email = confirm_same_person_email
      @request = request
    end

    def call
      raise Error, "Choose email or a printed sign-up code" unless %w[email code].include?(@delivery)

      EmployeeLinks.require_staff!(@actor, @link.company)
      employee = @link.employee
      result = ApplicationRecord.transaction do
        employee.lock!
        @link.lock!
        raise Error, "Only an open invite can be resent" unless @link.invited?
        raise Error, "Only active employees can be invited" unless employee.active?
        raise Error, "The employee app isn't turned on for this company" unless @link.portal_enabled?

        if @delivery == "email"
          @link.claim_user = check_email!(employee)
        end
        credentials = Credentials.issue(@link, delivery: @delivery, email: employee.email)
        @link.save!
        path = EmployeeLinks.invite_path(@link.claim_user)
        EmployeeLinks.audit!(@link, "invite_resent", user: @actor, request: @request,
          metadata: { delivery: @delivery, path: path, expires_at: @link.invite_expires_at.iso8601 })
        Invite::Result.new(link: @link, token: credentials.token, code: credentials.code, path: path, email_status: nil)
      end
      return result unless @delivery == "email"

      result.with(email_status: InviteEmail.deliver(link: result.link, token: result.token, path: result.path))
    end

    private

    def check_email!(employee)
      Invite.new(employee: employee, actor: @actor, delivery: "email",
        confirm_same_person_email: @confirm_same_person_email, request: @request).send(:check_email!)
    end
  end
end
