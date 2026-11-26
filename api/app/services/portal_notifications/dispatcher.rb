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
    EMPLOYEE_CHANNEL = "employee_portal_notification"
    BATCH_KEY_V2_PREFIX = "portal-notification-v2-"

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

    # Batches are versioned (portal-notification-v2-...) and never mix clients
    # or destinations. For legacy pre-v2 batches, a retry keeps the old key and
    # renders with the legacy generic renderer ONLY if every row in that batch
    # is still authorized; otherwise revoked rows are dropped and the remaining
    # authorized rows are split and re-keyed into fresh v2 batches so revoked
    # clients are never rendered and a mutated payload never reuses an old key.
    def claim(recipient_key)
      PortalNotificationDelivery.transaction do
        rows = due_scope.where(recipient_key: recipient_key).order(:id).lock("FOR UPDATE SKIP LOCKED")
          .includes(:user, portal_notification_event: [ :company, :subject ]).to_a
        kept = rows.reject { |row| skip_if_ineligible!(row) || retime_and_defer!(row) }
        fresh_rows, attempted_rows = kept.partition { |row| row.batch_key.nil? }

        claimed = claim_v2_groups(recipient_key, fresh_rows)
        attempted_rows.group_by(&:batch_key).each do |previous_key, group|
          claimed.concat(claim_attempted_batch(recipient_key, previous_key, group))
        end
        claimed
      end
    end

    def claim_v2_groups(recipient_key, rows, salt: nil)
      rows.group_by do |row|
        [
          row.delivery_mode,
          Email.destination_group(row.event, delivery_mode: row.delivery_mode),
          row.company_id,
          row.event.company&.demo? == true
        ]
      end.map do |(mode, destination, company_id, demo), group|
        ids = group.map(&:id).sort
        key = v2_batch_key(recipient_key: recipient_key, mode: mode, destination: destination, company_id: company_id,
          demo: demo, ids: ids, salt: salt)
        build_claimed_group(group: group, key: key, mode: mode, events: group.map(&:event), legacy_renderer: false)
      end
    end

    def claim_attempted_batch(recipient_key, previous_key, group)
      all_batch_rows = PortalNotificationDelivery.where(batch_key: previous_key).order(:id)
        .includes(portal_notification_event: [ :company, :subject ]).to_a
      kept_ids = group.map(&:id)
      all_authorized = all_batch_rows.any? && all_batch_rows.all? { |row| kept_ids.include?(row.id) }
      all_events = all_batch_rows.map(&:event)

      if !v2_batch_key?(previous_key)
        if all_authorized
          return [ build_claimed_group(group: group, key: previous_key, mode: group.first.delivery_mode,
            events: all_events, legacy_renderer: true) ]
        end

        return claim_v2_groups(recipient_key, group, salt: "reconciled:#{previous_key}")
      end

      # Single-company generic v2 batches contain no client/subject/date details,
      # so keeping the original key and generic payload preserves provider-side
      # deduplication if a previous attempt timed out after provider acceptance.
      if all_authorized || (!Email.payroll_review_batch?(all_events) && all_events.map(&:company_id).uniq.one?)
        [ build_claimed_group(group: group, key: previous_key, mode: group.first.delivery_mode,
          events: all_events, legacy_renderer: false) ]
      else
        claim_v2_groups(recipient_key, group, salt: "reconciled:#{previous_key}")
      end
    end

    def build_claimed_group(group:, key:, mode:, events:, legacy_renderer:)
      ids = group.map(&:id).sort
      PortalNotificationDelivery.where(id: ids).update_all(
        [ "attempts = attempts + 1, claimed_at = ?, batch_key = ?, updated_at = ?", now, key, now ])
      first = group.first
      {
        user: effective_user_for(first),
        address: first.address,
        audience: first.event.audience,
        ids: ids,
        key: key,
        mode: mode,
        events: events,
        legacy_renderer: legacy_renderer
      }
    end

    def v2_batch_key?(key)
      key.to_s.start_with?(BATCH_KEY_V2_PREFIX)
    end

    def v2_batch_key(recipient_key:, mode:, destination:, company_id:, demo:, ids:, salt: nil)
      digest_input = [ recipient_key, mode, destination, company_id, demo, ids.join(","), salt ].compact.join(":")
      "#{BATCH_KEY_V2_PREFIX}#{Digest::SHA256.hexdigest(digest_input)[0, 48]}"
    end

    def retime_and_defer!(row)
      return false unless row.batch_key.nil? && row.attempts.zero?

      user = effective_user_for(row)
      return false unless user

      current_mode = Preferences.mode_for(user, row.event.category)
      return false unless PortalNotificationDelivery::DELIVERY_MODES.include?(current_mode)
      return false if current_mode == row.delivery_mode

      new_deliver_after = PortalNotifications.deliver_after_for(current_mode, row.event.occurred_at)
      row.update!(delivery_mode: current_mode, deliver_after: new_deliver_after)
      new_deliver_after > now
    end

    def effective_user_for(row)
      return row.user if row.user_id.present?
      return nil unless row.event.audience == "staff"

      Recipients.eligible_account_user_for_email(row.recipient_email, row.event)
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

      user = effective_user_for(row)
      # Rechecked before every send and retry, so a stale queued row for a
      # demo address that has left the allow-list (or, for an employee
      # alert, a demo whose employee app is off) sends nothing.
      unless DemoOutbound.permit?(company: event.company, email: row.address, channel: channel_for(event.audience), user: user)
        return "recipient_not_allowed"
      end
      return nil unless user
      if row.user_id.nil? && PortalNotificationDelivery.where(portal_notification_event_id: event.id, user_id: user.id).where.not(id: row.id).exists?
        return "coalesced"
      end
      return "preference_off" if Preferences.mode_for(user, event.category) == "off"
      # Reading the conversation first makes a still-pending alert unnecessary.
      return "already_read" if event.message_event? && !event.subject.unread_for?(user)

      nil
    end

    def deliver(group)
      email = Email.new(
        audience: group.fetch(:audience),
        delivery_mode: group.fetch(:mode),
        events: group.fetch(:events),
        app_user: group.fetch(:user).present?,
        legacy_renderer: group.fetch(:legacy_renderer, false)
      )
      demo_company = group.fetch(:events).map(&:company).find { |company| company&.demo? }
      # An employee alert is rechecked at the transport against the demo's
      # employee app too (the demo kill switch may have run since the claim).
      response = DemoOutbound.scoped(demo_company, channel: channel_for(group.fetch(:audience))) do
        Transport.deliver(email.payload(from: Transport.from_email, to: group.fetch(:address)), idempotency_key: group.fetch(:key))
      end
      if response["suppressed"]
        complete!(group, status: "skipped", skip_reason: "recipient_not_allowed")
        return false
      end
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

    def channel_for(audience)
      audience == "employee" ? EMPLOYEE_CHANNEL : "portal_notification"
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
