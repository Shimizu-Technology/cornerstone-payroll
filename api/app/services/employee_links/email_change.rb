# frozen_string_literal: true

require "cgi"

module EmployeeLinks
  # What a change to Employee#email means for the employee app. The employer
  # (client or staff) is the source of truth for the address, so the edit is
  # never blocked; instead, inside the edit's transaction (the employee row
  # is already locked, step 1 of the EmployeeLinks lock order):
  #
  # - an open invite closes: its token and code stop working and its invite
  #   generation moves on, so a Clerk sign-up started for it can't bind. Staff
  #   or the client resend it to the new address.
  # - the change is audited with who made it and both addresses, as side
  #   effects, so the edit's own audit is still written.
  # - a pending notice to the OLD address is saved when the person has an
  #   invite or an active or former link. The job sends it after commit and
  #   a recurring sweep retries what's left (the ActivationNoticeEmail
  #   pattern), so a queue outage can't lose it.
  #
  # An active link's sign-in is the login's own email, which this never
  # touches. Callers that bypass model callbacks (bulk updates) call it
  # themselves with each row's original address.
  module EmailChange
    class DeliveryError < StandardError; end

    CHANNEL = "employee_email_change_notice"
    MAX_ATTEMPTS = 5
    RETRY_AFTER = 10.minutes

    module_function

    # actor: the user making the change, when not the request's Current.user.
    def call(employee:, from:, to:, actor: nil)
      return if EmployeeLinks.normalized_email(from).to_s == EmployeeLinks.normalized_email(to).to_s

      links = EmployeeAccountLink.where(employee_id: employee.id).where.not(status: "revoked").order(:id).lock.to_a
      return if links.empty?

      user = actor || Current.user
      audit_actor = change_actor(user)
      now = Time.current
      EmployeeLinks.side_effect_audit do
        closed = links.select(&:invited?).each { |link| close_invite!(link, now, user, audit_actor) }
        record_audit!(employee, from, to, closed, user, audit_actor)
      end
      return unless links.any? { |link| link.invited? || link.active? || link.former? }

      schedule_notice!(employee, from)
    end

    def close_invite!(link, now, user, audit_actor)
      link.update!(invite_token_digest: nil, invite_code_digest: nil, invite_expires_at: now,
        invite_generation: link.invite_generation.to_i + 1)
      EmployeeLinks.audit!(link, "invite_closed_by_email_change", user: user, actor: audit_actor)
    end

    def record_audit!(employee, from, to, closed, user, audit_actor)
      AuditLog.record!(
        user: user, actor: audit_actor, organization_id: employee.company.organization_id, company_id: employee.company_id,
        action: "employee_links#contact_email_changed", record_type: "employees", record_id: employee.id,
        subject_name: employee.display_name, event_category: "security",
        metadata: { from_email: EmployeeLinks.normalized_email(from).presence, to_email: EmployeeLinks.normalized_email(to).presence,
                    closed_invite_link_ids: closed.map(&:id) }.compact
      )
    end

    # Who made the change: the given or signed-in client or staff user, the
    # employee, or a named system path.
    def change_actor(user)
      return AuditActor.for_user(user) if user

      Current.actor || AuditActor.system_job("Employee email change")
    end

    # Saved in the change's transaction, one row (and one change_id) per
    # committed change; sent after commit.
    def schedule_notice!(employee, from)
      to = EmployeeLinks.normalized_email(from)
      return unless EmployeeLinks.email_format?(to)

      notice = EmployeeEmailChangeNotice.create!(company_id: employee.company_id, employee: employee,
        change_id: SecureRandom.uuid, recipient_email: to, status: "pending")
      notice_id = notice.id
      ActiveRecord.after_all_transactions_commit { enqueue_delivery(notice_id) }
      notice
    end

    # A failed enqueue never fails the committed edit; the sweep sends it.
    def enqueue_delivery(notice_id)
      SendEmployeeEmailChangeNoticeJob.perform_later(notice_id)
    rescue StandardError => error
      Rails.logger.warn("[EmployeeLinks::EmailChange] Couldn't enqueue notice #{notice_id} (#{error.class}); left for the sweep")
    end

    # Sends a pending or failed notice. Returns :sent, :captured, :skipped
    # or :failed; on a transport failure it records the attempt and raises
    # DeliveryError, whose message names only the notice and error class
    # (never the address), so the job's retry log can't leak it.
    def deliver_pending!(notice_id)
      notice = EmployeeEmailChangeNotice.find_by(id: notice_id)
      return :skipped unless notice

      outcome = :skipped
      failure = nil
      notice.with_lock do
        next if %w[sent skipped].include?(notice.status)
        if notice.status == "failed" && notice.attempts >= MAX_ATTEMPTS
          outcome = :failed
          next
        end

        to = notice.recipient_email
        company = notice.company
        unless EmployeeLinks.email_format?(to) && PortalNotifications.delivery_enabled? &&
            PortalNotifications::Transport.configured? && DemoOutbound.permit?(company: company, email: to, channel: CHANNEL)
          notice.update!(status: "skipped")
          next
        end

        attempts = notice.attempts + 1
        begin
          response = DemoOutbound.scoped(company, channel: CHANNEL) do
            PortalNotifications::Transport.deliver(payload(company, to), idempotency_key: "employee-email-changed-#{notice.change_id}")
          end
          if response["suppressed"]
            notice.update!(status: "skipped", attempts: attempts)
          else
            notice.update!(status: "sent", attempts: attempts, sent_at: Time.current)
            outcome = response["captured"] || response["staging_captured"] ? :captured : :sent
          end
        rescue StandardError => error
          Rails.logger.warn("[EmployeeLinks::EmailChange] Notice #{notice.id} failed: #{error.class}")
          notice.update!(status: "failed", attempts: attempts)
          failure = error
          outcome = :failed
        end
      end
      raise DeliveryError, "Email change notice #{notice.id} failed: #{failure.class}" if failure

      outcome
    end

    # The recovery sweep: pending notices whose job was lost, and failed
    # ones due another try.
    def retry_unsent!(limit: 100)
      due = EmployeeEmailChangeNotice.where(status: "pending")
        .or(EmployeeEmailChangeNotice.where(status: "failed").where(attempts: ...MAX_ATTEMPTS).where(updated_at: ..RETRY_AFTER.ago))
        .order(:id).limit(limit)
      due.pluck(:id).count do |id|
        deliver_pending!(id)
        true
      rescue DeliveryError
        false
      end
    end

    def payload(company, to)
      employer = company.name
      line = "The email for your #{employer} employee app was changed. If you didn't expect this, contact #{employer}."
      {
        from: PortalNotifications::Transport.from_email, to: to,
        subject: "The email for your #{employer} employee app was changed",
        text: line, html: "<p>#{CGI.escapeHTML(line)}</p>"
      }
    end
  end
end
