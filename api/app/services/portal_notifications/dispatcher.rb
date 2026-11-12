# frozen_string_literal: true

require "digest"

module PortalNotifications
  # Sends due ledger rows as one email per recipient and delivery mode.
  # Each row is re-authorized immediately before every send or retry.
  class Dispatcher
    CLAIM_TIMEOUT = 10.minutes
    RETRY_BACKOFF = [ 1.minute, 5.minutes, 30.minutes, 2.hours ].freeze
    MAX_ATTEMPTS = RETRY_BACKOFF.size + 1
    RECIPIENT_LIMIT = 200

    def self.run!(now: Time.current)
      new(now).run!
    end

    def initialize(now)
      @now = now
    end

    def run!
      keys = due_scope.distinct.order(:recipient_key).limit(RECIPIENT_LIMIT).pluck(:recipient_key)
      keys.sum { |key| claim(key).count { |group| deliver(group) } }
    end

    private

    attr_reader :now

    def due_scope
      PortalNotificationDelivery.pending.where(channel: "email")
        .where("deliver_after <= ?", now)
        .where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
        .where("claimed_at IS NULL OR claimed_at < ?", now - CLAIM_TIMEOUT)
    end

    # A batch already attempted keeps its idempotency key and rebuilds the same
    # email from every row in that attempt, even if some rows have since been
    # skipped. If the provider accepted the earlier attempt but the response was
    # lost, the retry is the identical request and is deduplicated, never a
    # second email under a new key.
    def claim(recipient_key)
      PortalNotificationDelivery.transaction do
        rows = due_scope.where(recipient_key: recipient_key).order(:id).lock("FOR UPDATE SKIP LOCKED")
          .includes(:user, portal_notification_event: :subject).to_a
        kept = rows.reject { |row| skip_if_ineligible!(row) }
        # New batches never mix destinations; an attempted batch keeps its rows.
        kept.group_by { |row| [ row.delivery_mode, row.batch_key, (Email.destination_group(row.event) unless row.batch_key) ] }
          .map do |(mode, previous_key, destination), group|
          ids = group.map(&:id).sort
          key = previous_key || "portal-notification-#{Digest::SHA256.hexdigest("#{recipient_key}:#{mode}:#{destination}:#{ids.join(',')}")[0, 48]}"
          events = previous_key ? attempted_events(previous_key) : group.map(&:event)
          PortalNotificationDelivery.where(id: ids).update_all(
            [ "attempts = attempts + 1, claimed_at = ?, batch_key = ?, updated_at = ?", now, key, now ])
          first = group.first
          { user: first.user, address: first.address, audience: first.event.audience, ids: ids, key: key, mode: mode,
            events: events }
        end
      end
    end

    def attempted_events(batch_key)
      PortalNotificationDelivery.where(batch_key: batch_key).order(:id).includes(:portal_notification_event).map(&:event)
    end

    def skip_if_ineligible!(row)
      reason = skip_reason_for(row)
      return false unless reason

      row.update!(status: "skipped", skip_reason: reason, claimed_at: nil, completed_at: now)
      true
    end

    def skip_reason_for(row)
      event = row.event
      return "email_delivery_disabled" unless PortalNotifications.delivery_enabled?
      return "email_not_configured" unless Transport.configured?
      return "resource_unavailable" unless Recipients.subject_available?(event)

      revoked = Recipients.revocation_reason(row)
      return revoked if revoked
      return nil unless row.user
      return "preference_off" if Preferences.mode_for(row.user, event.category) == "off"
      # Reading the conversation first makes a still-pending alert unnecessary.
      return "already_read" if event.message_event? && !event.subject.unread_for?(row.user)

      nil
    end

    def deliver(group)
      email = Email.new(audience: group.fetch(:audience), delivery_mode: group.fetch(:mode), events: group.fetch(:events),
        app_user: group.fetch(:user).present?)
      response = Transport.deliver(email.payload(from: Transport.from_email, to: group.fetch(:address)), idempotency_key: group.fetch(:key))
      if response["staging_captured"]
        complete!(group, status: "skipped", skip_reason: "staging_contained")
        Rails.logger.info("[PortalNotification] staging contained batch=#{group[:key]} deliveries=#{group[:ids].size}")
        return false
      end

      complete!(group, status: "sent", sent_at: now, provider_message_id: response["id"].to_s.first(128).presence)
      Rails.logger.info("[PortalNotification] accepted batch=#{group[:key]} deliveries=#{group[:ids].size}")
      true
    rescue StandardError => error
      record_failure!(group, error)
      false
    end

    def complete!(group, **attributes)
      PortalNotificationDelivery.where(id: group[:ids]).update_all(
        attributes.merge(claimed_at: nil, next_attempt_at: nil, last_error_class: nil, completed_at: now, updated_at: now))
    end

    # Only the error class is kept or logged: provider messages can echo
    # recipients or payload content.
    def record_failure!(group, error)
      PortalNotificationDelivery.where(id: group[:ids]).find_each do |row|
        if row.attempts >= MAX_ATTEMPTS
          row.update!(status: "failed", claimed_at: nil, next_attempt_at: nil, last_error_class: error.class.name, completed_at: now)
        else
          row.update!(claimed_at: nil, next_attempt_at: now + RETRY_BACKOFF.fetch(row.attempts - 1), last_error_class: error.class.name)
        end
      end
      Rails.logger.warn("[PortalNotification] delivery failed batch=#{group[:key]} error=#{error.class.name}")
    end
  end
end
