# frozen_string_literal: true

module EmployeeLinks
  # Sign-up for a person with no Payroll login (POST /api/v1/employee/activation).
  #
  # After the shared check it creates, or on a retry reuses, the link's pending
  # portal_employee user and records it on the still-invited link. It then
  # creates a Clerk invitation with notify: false and returns its sign-up URL
  # instead of emailing it. The link becomes active only when /auth/me binds
  # the Clerk account (Bind).
  #
  # Outcomes: :sign_up (with url), :sign_in, :failed, :unavailable. :sign_in is
  # one answer for every reason a new account can't start with that email, so
  # it never says whether an address already has a login.
  class Activate
    Result = Data.define(:outcome, :url)

    def self.call(...)
      new(...).call
    end

    def initialize(token:, code:, date_of_birth:, ssn_last4:, email:, use_for_notices: false, request: nil,
      invitations: PayrollInvitation.new)
      @check = { token: token, code: code, date_of_birth: date_of_birth, ssn_last4: ssn_last4 }
      @email = EmployeeLinks.normalized_email(email)
      @use_for_notices = ActiveModel::Type::Boolean.new.cast(use_for_notices) == true
      @request = request
      @invitations = invitations
    end

    def call
      return Result.new(outcome: :failed, url: nil) unless EmployeeLinks.email_format?(@email)

      prepared = Verify.call(**@check, request: @request) { |link| prepare(link) }
      return Result.new(outcome: :failed, url: nil) unless prepared
      return Result.new(outcome: :sign_in, url: nil) if prepared == :sign_in

      start_clerk_sign_up(*prepared)
    end

    private

    def prepare(link)
      return :sign_in if link.claim_user_id.present?

      pending = link.user
      if pending && !(pending.portal_employee? && pending.awaiting_clerk_binding?)
        return :sign_in
      end
      return :sign_in if EmployeeLinks.login_email_taken?(@email, except_user_id: pending&.id)
      return :sign_in if EmployeeContactValidator.placeholder_email?(@email, organization_id: link.company.organization_id) ||
        EmployeeContactValidator.structural_placeholder_email?(@email)

      user = pending || User.new(role: :portal_employee, company: link.company, organization: link.company.organization,
        invitation_status: "pending", active: true)
      user.assign_attributes(email: @email, name: link.employee.display_name)
      # A savepoint keeps the check's transaction usable if another sign-up
      # takes this address at the same moment.
      User.transaction(requires_new: true) do
        user.save!
        link.update!(user: user, sign_up_email_for_notices: @use_for_notices)
      end
      EmployeeLinks.audit!(link, "sign_up_started", actor: AuditActor.employee(link.employee), request: @request,
        metadata: { retry: pending.present?, via: link.invite_delivery })
      [ link, user ]
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      :sign_in
    end

    def start_clerk_sign_up(link, user)
      redirect_url = AppUrl.sign_up_redirect_url(link.company)
      return Result.new(outcome: :unavailable, url: nil) unless redirect_url

      result = @invitations.send_invite(user, redirect_url: redirect_url,
        metadata: { payroll_employee_link_id: link.id })
      return Result.new(outcome: :sign_up, url: result[:url]) if result[:success] && result[:url].present?

      # Clerk refuses an address that already has an account; that is the same
      # answer as any other address that can't start a new account here.
      status = result[:status_code].to_i
      Result.new(outcome: status.between?(400, 499) || result[:error] == PayrollInvitation::ACCEPTED_MESSAGE ? :sign_in : :unavailable, url: nil)
    end
  end
end
