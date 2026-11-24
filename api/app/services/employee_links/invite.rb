# frozen_string_literal: true

module EmployeeLinks
  # Issues an employee app invite. It never creates a login: the
  # portal_employee user is created at sign-up (Activate), or an existing
  # login confirmed as the same person claims the link (Claim).
  #
  # delivery: "email" sends a link with a random token to the employee's own
  # email (M4-3 invite guard); "code" returns a one-time 10-character sign-up
  # code to print. Only digests are stored, and the plaintext is returned once.
  class Invite
    Result = Data.define(:link, :token, :code, :path, :email_status)

    def self.call(...)
      new(...).call
    end

    def initialize(employee:, actor:, delivery:, confirm_same_person_email: false, request: nil)
      @employee = employee
      @actor = actor
      @delivery = delivery.to_s
      @confirm_same_person_email = ActiveModel::Type::Boolean.new.cast(confirm_same_person_email) == true
      @request = request
    end

    def call
      raise Error, "Choose email or a printed sign-up code" unless %w[email code].include?(@delivery)

      company = @employee.company
      EmployeeLinks.require_staff!(@actor, company)

      result = ApplicationRecord.transaction do
        @employee.lock!
        raise Error, "Only active employees can be invited" unless @employee.active?

        open_link = @employee.employee_account_links.where(status: %w[invited active]).order(:id).lock.first
        raise Error, "This employee already has employee app access" if open_link&.active?
        raise Error, "This employee already has an invite. Resend it instead." if open_link

        link = @employee.employee_account_links.new(company: company, invited_by: @actor, status: "invited")
        raise Error, "The employee app isn't turned on for this company" unless link.portal_enabled?

        claim_user = @delivery == "email" ? check_email! : nil
        credentials = Credentials.issue(link, delivery: @delivery, email: @employee.email)
        link.claim_user = claim_user
        link.save!

        path = claim_user ? "claim" : "sign_up"
        EmployeeLinks.audit!(link, "invited", user: @actor, request: @request,
          metadata: { delivery: @delivery, path: path, expires_at: link.invite_expires_at.iso8601 })
        Result.new(link: link, token: credentials.token, code: credentials.code, path: path, email_status: nil)
      end

      return result unless @delivery == "email"

      result.with(email_status: InviteEmail.deliver(link: result.link, token: result.token, path: result.path))
    end

    private

    # Runs the M4-3 invite guard and routes an address that belongs to a login
    # already confirmed as this person to the claim path.
    def check_email!
      validation = EmployeeContactValidator.validate_for_invite(
        @employee, company: @employee.company, allow_same_person_login: @confirm_same_person_email, actor: @actor
      )
      raise Error, validation.errors.values.flatten.uniq.join("; ") unless validation.valid?
      raise Error, "The employee app address isn't set up for this company" unless AppUrl.origin_for(@employee.company)

      EmployeeContactValidator.record_same_person_confirmation_audit!(
        employee: @employee, result: validation, actor: @actor, company: @employee.company,
        ip_address: @request&.remote_ip, user_agent: @request&.user_agent, request_id: @request&.request_id
      )
      login = validation.matched_login_user
      login if login&.payroll_access_allowed? && login.clerk_id.present?
    end
  end
end
