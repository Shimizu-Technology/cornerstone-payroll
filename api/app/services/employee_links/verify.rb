# frozen_string_literal: true

module EmployeeLinks
  # The sign-up check shared by activation and claim: a token or one-time
  # code, plus date of birth and SSN last 4.
  #
  # Every failure looks the same to the caller. The link row is locked while
  # it is checked, so concurrent guesses can't slip past the limit: 5 failures
  # lock the link for 24 hours (staff can unlock it), and 3 locks at one
  # company within an hour alert staff.
  #
  # On success the block runs with the locked link inside the same
  # transaction; its return value is the outcome. A block that returns nil
  # counts as a generic failure without using up an attempt, because the
  # person proved who they are but the link can't be used this way.
  #
  # Only a link that could still be used counts failures: guesses against an
  # expired, closed or switched-off invite write nothing, so a match there
  # can't be told apart from a miss by how long the answer takes.
  #
  # lock_users: logins the caller will change, given the link as first read
  # (unlocked). They are locked before the link (EmployeeLinks lock order);
  # if the link's login changed in between, the check fails generically.
  #
  # admit: whether the caller could ever use the link. It is asked about the
  # first, unlocked read and again about the locked row, before anything on
  # the link changes; a link it refuses is treated like no match: nothing is
  # locked, counted or written on it.
  class Verify
    ALERT_LOCKS = 3
    ALERT_WINDOW = 1.hour
    # Advisory lock namespace for "lock alerts of one company".
    ALERT_LOCK_NAMESPACE = 450_402
    DOB_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
    SSN4_PATTERN = /\A\d{4}\z/
    # Compared against when no link matches, so a miss does the same work.
    DUMMY_SECRET = "0000-00-00|0000"

    def self.call(**options, &block)
      new(**options).call(&block)
    end

    def initialize(token:, code:, date_of_birth:, ssn_last4:, request: nil, lock_users: nil, admit: nil)
      @credential = Credentials.select(token: token, code: code)
      @date_of_birth = date_of_birth
      @ssn_last4 = ssn_last4
      @request = request
      @lock_users = lock_users
      @admit = admit
    end

    # Returns the block's outcome, or nil for every kind of failure.
    def call
      lookup = lookup_attributes
      supplied = supplied_secret
      unless lookup
        ActiveSupport::SecurityUtils.secure_compare(DUMMY_SECRET, supplied)
        return
      end

      alert_company = nil
      outcome = ApplicationRecord.transaction do
        link = lock_link(lookup)
        unless link
          ActiveSupport::SecurityUtils.secure_compare(DUMMY_SECRET, supplied)
          next
        end

        now = Time.current
        clear_expired_lock!(link, now)
        matched = ActiveSupport::SecurityUtils.secure_compare(expected_secret(link.employee), supplied)
        usable = link.invite_open?(now) && !link.activation_locked?(now) && link.employee.active? && link.portal_enabled?

        if matched && usable
          link.update!(failed_activation_attempts: 0) if link.failed_activation_attempts.positive?
          result = yield(link)
          raise ActiveRecord::Rollback unless result

          next result
        end

        alert_company = record_failure!(link, now) if usable && !matched
        nil
      end
      alert_staff!(alert_company) if alert_company
      outcome
    end

    private

    def lookup_attributes
      case @credential&.kind
      when :token then { invite_token_digest: EmployeeAccountLink.token_digest(@credential.value) }
      when :code then { invite_code_digest: EmployeeAccountLink.code_digest(@credential.value) }
      end
    end

    def lock_link(lookup)
      return EmployeeAccountLink.lock.find_by(lookup) unless @lock_users || @admit

      first_read = EmployeeAccountLink.find_by(lookup)
      return unless first_read && (@admit.nil? || @admit.call(first_read))

      EmployeeLinks.lock_users!(Array(@lock_users.call(first_read)).map(&:id)) if @lock_users
      link = EmployeeAccountLink.lock.find_by(lookup.merge(id: first_read.id))
      link if link&.user_id == first_read.user_id && (@admit.nil? || @admit.call(link))
    end

    def supplied_secret
      dob = @date_of_birth.is_a?(String) && DOB_PATTERN.match?(@date_of_birth.strip) ? @date_of_birth.strip : "x"
      ssn = @ssn_last4.is_a?(String) && SSN4_PATTERN.match?(@ssn_last4.strip) ? @ssn_last4.strip : "x"
      "#{dob}|#{ssn}"
    end

    # A record missing either value can never match: "missing" is longer than
    # any supplied value's slot, and secure_compare also checks length.
    def expected_secret(employee)
      dob = employee.date_of_birth&.iso8601 || "missing"
      ssn = employee.ssn_digits.to_s
      ssn = ssn.length == 9 ? ssn.last(4) : "missing"
      "#{dob}|#{ssn}"
    end

    def clear_expired_lock!(link, now)
      return unless link.activation_locked_until.present? && link.activation_locked_until <= now

      link.update!(failed_activation_attempts: 0, activation_locked_until: nil)
    end

    # Returns the company to alert about, if this failure locked a third link
    # there within the hour.
    def record_failure!(link, now)
      attempts = link.failed_activation_attempts + 1
      locking = attempts >= EmployeeAccountLink::MAX_FAILED_ATTEMPTS
      link.update!(
        failed_activation_attempts: attempts,
        activation_locked_at: locking ? now : link.activation_locked_at,
        activation_locked_until: locking ? now + EmployeeAccountLink::LOCK_DURATION : nil
      )
      EmployeeLinks.audit!(link, locking ? "activation_locked" : "activation_failed",
        actor: EmployeeLinks.verifier_actor, request: @request,
        metadata: { failed_attempts: attempts, locked_until: link.activation_locked_until&.iso8601 })
      return unless locking

      PayrollTelemetry.log(:warn, "employee_links.activation_locked", company_id: link.company_id,
        employee_account_link_id: link.id, request_id: @request&.request_id)
      # One count at a time per company, each after the last one committed,
      # so a burst of simultaneous locks still reaches the alert.
      ApplicationRecord.connection.select_value(
        ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", ALERT_LOCK_NAMESPACE, Integer(link.company_id) ])
      )
      recent = AuditLog.where(company_id: link.company_id, action: "employee_links#activation_locked")
        .where(created_at: (now - ALERT_WINDOW)..).count
      already_alerted = AuditLog.where(company_id: link.company_id, action: "employee_links#activation_lock_alert")
        .where(created_at: (now - ALERT_WINDOW)..).exists?
      return unless recent >= ALERT_LOCKS && !already_alerted

      AuditLog.record!(
        actor: EmployeeLinks.verifier_actor, user: nil,
        organization_id: link.company.organization_id, company_id: link.company_id,
        action: "employee_links#activation_lock_alert", record_type: "companies", record_id: link.company_id,
        subject_name: link.company.name, event_category: "security",
        metadata: { locks_in_window: recent, window_minutes: (ALERT_WINDOW / 60).to_i },
        ip_address: @request&.remote_ip, user_agent: @request&.user_agent, request_id: @request&.request_id
      )
      link.company_id
    end

    # Staff watch the error-level log events (M4 runbook, Alerts); the audit
    # row stays the record. M4-9 shows it in the admin screens.
    def alert_staff!(company_id)
      PayrollTelemetry.log(:error, "employee_links.activation_lock_alert", company_id: company_id,
        locks: ALERT_LOCKS, window_minutes: (ALERT_WINDOW / 60).to_i, request_id: @request&.request_id)
      Rails.error.report(StandardError.new("Employee app sign-up locks at company #{company_id}"),
        handled: true, severity: :warning, context: { company_id: company_id })
    end
  end
end
