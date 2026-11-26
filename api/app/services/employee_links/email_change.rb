# frozen_string_literal: true

require "cgi"

module EmployeeLinks
  # What a change to Employee#email means for the employee app. The employer
  # (client or staff) is the source of truth for the address, so the edit is
  # never blocked; instead, inside the edit's transaction (the employee row
  # is already locked by its UPDATE, first in the EmployeeLinks lock order):
  #
  # - an open invite closes: its token and code stop working and its invite
  #   generation moves on, so a Clerk sign-up started for it can't bind. Staff
  #   or the client resend it to the new address.
  # - the change is audited with who made it and both addresses.
  # - after commit, a short notice goes to the OLD address when the person
  #   has an invite or an active or former link.
  #
  # An active link's sign-in is the login's own email, which this never
  # touches.
  module EmailChange
    CHANNEL = "employee_email_change_notice"

    module_function

    def call(employee:, from:, to:)
      return if EmployeeLinks.normalized_email(from).to_s == EmployeeLinks.normalized_email(to).to_s

      links = EmployeeAccountLink.where(employee_id: employee.id).where.not(status: "revoked").order(:id).lock.to_a
      return if links.empty?

      now = Time.current
      closed = links.select(&:invited?).each { |link| close_invite!(link, now) }
      record_audit!(employee, from, to, closed)
      notify_after_commit(employee, from, now) if links.any? { |link| link.invited? || link.active? || link.former? }
    end

    def close_invite!(link, now)
      link.update!(invite_token_digest: nil, invite_code_digest: nil, invite_expires_at: now,
        invite_generation: link.invite_generation.to_i + 1)
      EmployeeLinks.audit!(link, "invite_closed_by_email_change", actor: change_actor)
    end

    def record_audit!(employee, from, to, closed)
      AuditLog.record!(
        actor: change_actor, organization_id: employee.company.organization_id, company_id: employee.company_id,
        action: "employee_links#contact_email_changed", record_type: "employees", record_id: employee.id,
        subject_name: employee.display_name, event_category: "security",
        metadata: { from_email: EmployeeLinks.normalized_email(from).presence, to_email: EmployeeLinks.normalized_email(to).presence,
                    closed_invite_link_ids: closed.map(&:id) }.compact
      )
    end

    # Who made the change: the signed-in client or staff user, the employee,
    # or a named system path.
    def change_actor
      return AuditActor.for_user(Current.user) if Current.user

      Current.actor || AuditActor.system_job("Employee email change")
    end

    def notify_after_commit(employee, from, changed_at)
      to = EmployeeLinks.normalized_email(from)
      return unless EmployeeLinks.email_format?(to)

      employee_id = employee.id
      ActiveRecord.after_all_transactions_commit do
        SendEmployeeEmailChangeNoticeJob.perform_later(employee_id, to, changed_at.to_i)
      rescue StandardError => error
        Rails.logger.warn("[EmployeeLinks::EmailChange] Couldn't enqueue the notice for employee #{employee_id}: #{error.class}")
      end
    end

    # Returns :sent, :captured or :skipped; raises when the transport fails so
    # the job retries with the same idempotency key.
    def deliver!(employee_id:, to:, changed_at:)
      employee = Employee.find_by(id: employee_id)
      return :skipped unless employee && EmployeeLinks.email_format?(to)
      return :skipped unless PortalNotifications.delivery_enabled? && PortalNotifications::Transport.configured?
      return :skipped unless DemoOutbound.permit?(company: employee.company, email: to, channel: CHANNEL)

      response = DemoOutbound.scoped(employee.company, channel: CHANNEL) do
        PortalNotifications::Transport.deliver(payload(employee.company, to),
          idempotency_key: "employee-email-changed-#{employee_id}-#{changed_at}")
      end
      return :skipped if response["suppressed"]

      response["captured"] || response["staging_captured"] ? :captured : :sent
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
