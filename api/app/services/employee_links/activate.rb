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
  # On a retry, a changed email (or name) is saved only together with the
  # replacement Clerk invitation, after Clerk confirmed the previous one is
  # closed, and only while the link is still on the same invite generation.
  # Until then the login keeps the address its open invitation was made for.
  #
  # Outcomes: :sign_up (with url), :sign_in, :failed, :unavailable. :sign_in is
  # one answer for every reason a new account can't start with that email, so
  # it never says whether an address already has a login.
  class Activate
    Result = Data.define(:outcome, :url)
    # attach: the link gets this login only when the invitation is saved (a
    # reused closed sign-up row; see EmployeeLinks.closed_pending_sign_up_for?).
    Prepared = Data.define(:link, :user, :generation, :changes, :attach)

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

      start_clerk_sign_up(prepared)
    end

    private

    def prepare(link)
      return :sign_in if link.claim_user_id.present?
      # A demo link signs up only from its own subdomain, on a guarded process.
      return :sign_in unless EmployeeLinks.demo_request_allowed?(link.company, @request&.headers&.[]("Origin"))
      # Answered like any other address that can't start a new account, and
      # checked before a pending login is created or attached.
      return :sign_in unless DemoOutbound.permit?(company: link.company, email: @email, channel: "employee_link_activation")

      pending = link.user
      # A pending login an admin deactivated never restarts a sign-up.
      if pending && !(pending.portal_employee? && pending.awaiting_clerk_binding? && pending.active?)
        return :sign_in
      end
      return :sign_in if EmployeeContactValidator.placeholder_email?(@email, organization_id: link.company.organization_id) ||
        EmployeeContactValidator.structural_placeholder_email?(@email)
      if EmployeeLinks.login_email_taken?(@email, except_user_id: pending&.id)
        reused = EmployeeLinks.reusable_pending_login(@email, link.employee) unless pending
        return :sign_in unless reused

        return reuse_closed_sign_up(link, reused)
      end

      retried = pending.present?
      changes = { email: @email, name: link.employee.display_name }
      if pending
        # A retry: nothing on the login changes until the new invitation is
        # saved (send_invite). The link already points at it.
        changes = changes.reject { |field, value| pending.public_send(field) == value }
        link.update!(sign_up_email_for_notices: @use_for_notices) if changes.empty?
      else
        pending = User.new(role: :portal_employee, company: link.company, organization: link.company.organization,
          invitation_status: "pending", active: true, **changes)
        changes = {}
        # A savepoint keeps the check's transaction usable if another sign-up
        # takes this address at the same moment.
        User.transaction(requires_new: true) do
          pending.save!
          link.update!(user: pending, sign_up_email_for_notices: @use_for_notices)
        end
      end
      EmployeeLinks.audit!(link, "sign_up_started", actor: AuditActor.employee(link.employee), request: @request,
        metadata: { retry: retried, via: link.invite_delivery })
      Prepared.new(link: link, user: pending, generation: link.invite_generation, changes: changes, attach: false)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      :sign_in
    end

    # The same person's earlier unfinished sign-up: the row comes back (active,
    # this address and name) only together with its new Clerk invitation,
    # which first confirms the old one closed. Nothing changes here.
    def reuse_closed_sign_up(link, user)
      EmployeeLinks.audit!(link, "sign_up_started", actor: AuditActor.employee(link.employee), request: @request,
        metadata: { retry: false, reused_login: true, via: link.invite_delivery })
      Prepared.new(link: link, user: user, generation: link.invite_generation, attach: true,
        # It never had a session, so no fence date carries over.
        changes: { email: @email, name: link.employee.display_name, active: true, deactivated_at: nil })
    end

    # A demo's Clerk invitation is issued under the company's issuance lock
    # (EmployeeLinks.lock_for_issuance!), re-checking the app is still on, so
    # the demo kill switch never runs halfway through one.
    def start_clerk_sign_up(prepared)
      return issue_clerk_sign_up(prepared) unless prepared.link.company.demo?

      ApplicationRecord.transaction do
        EmployeeLinks.lock_for_issuance!(prepared.link.company)
        if EmployeeAccountLink.portal_enabled_for?(prepared.link.company.reload)
          issue_clerk_sign_up(prepared)
        else
          Result.new(outcome: :unavailable, url: nil)
        end
      end
    end

    def issue_clerk_sign_up(prepared)
      link = prepared.link
      redirect_url = AppUrl.sign_up_redirect_url(link.company)
      return Result.new(outcome: :unavailable, url: nil) unless redirect_url

      result = @invitations.send_invite(prepared.user, redirect_url: redirect_url, attributes: prepared.changes,
        metadata: { payroll_employee_link_id: link.id, payroll_invite_generation: prepared.generation }) do |user|
        commit_retry?(link.id, user, prepared)
      end
      return Result.new(outcome: :sign_up, url: result[:url]) if result[:success] && result[:url].present?

      # Clerk refuses an address that already has an account; that is the same
      # answer as any other address that can't start a new account here.
      status = result[:status_code].to_i
      sign_in = status.between?(400, 499) || result[:error] == PayrollInvitation::ACCEPTED_MESSAGE ||
        result[:conflict] == :email_taken
      Result.new(outcome: sign_in ? :sign_in : :unavailable, url: nil)
    end

    # Runs under the login's lock, then takes the link's (EmployeeLinks lock
    # order): the link must still be the same open invite, on this login and
    # generation, before the new invitation (and any new email) is saved.
    # The controller's system scope covers this, as it does the check.
    def commit_retry?(link_id, user, prepared)
      link = EmployeeAccountLink.lock.find_by(id: link_id)
      return false unless link&.invite_open? && link.invite_generation == prepared.generation
      return false unless prepared.attach ? link.user_id.nil? : link.user_id == user.id
      if prepared.attach
        # Still the same closed sign-up for this person, re-read under its lock.
        return false unless EmployeeLinks.closed_pending_sign_up_for?(user, link.employee)

        link.update!(user: user, sign_up_email_for_notices: @use_for_notices)
        return true
      end
      return false unless user.active?
      return true if prepared.changes.empty?

      email = prepared.changes[:email]
      if email && EmployeeLinks.login_email_taken?(email, except_user_id: user.id)
        # Answered like any other taken address (send_invite: :email_taken).
        raise ActiveRecord::RecordNotUnique, "Sign-up email already has a login"
      end

      link.update!(sign_up_email_for_notices: @use_for_notices)
      true
    end
  end
end
