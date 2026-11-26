# frozen_string_literal: true

require "digest"
require "securerandom"

module PortalNotifications
  # Sends due ledger rows as one email per recipient and delivery mode.
  # Each row is re-authorized from fresh records immediately before rendering,
  # attempted payloads are persisted verbatim for retries, and DB locks are
  # never held across outbound provider HTTP calls.
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
      # Truncate to PostgreSQL microsecond precision so claimed_at equality checks match stored timestamps.
      @now = now.change(usec: now.usec)
      @claim_token = SecureRandom.hex(16)
    end

    def run!
      keys = due_scope.distinct.order(:recipient_key).limit(RECIPIENT_LIMIT).pluck(:recipient_key)
      keys.sum { |key| claim(key).count { |group| deliver_claimed(group) } }
    end

    private

    attr_reader :now, :claim_token

    def due_scope
      PortalNotificationDelivery.pending.where(channel: "email")
        .where("deliver_after <= ?", now)
        .where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
        .where("claimed_at IS NULL OR claimed_at < ?", now - CLAIM_TIMEOUT)
    end

    def due_row?(row)
      row.status == "pending" &&
        row.channel == "email" &&
        row.deliver_after <= now &&
        (row.next_attempt_at.nil? || row.next_attempt_at <= now) &&
        !actively_claimed?(row)
    end

    def actively_claimed?(row)
      row.claimed_at.present? && row.claimed_at >= now - CLAIM_TIMEOUT
    end

    # Locks whole batches in ascending id order before mutating any sibling, so
    # sibling reconciliation can never race another worker's claim.
    def claim(recipient_key)
      PortalNotificationDelivery.transaction do
        candidates = due_scope.where(recipient_key: recipient_key).order(:id).pluck(:id, :batch_key)
        return [] if candidates.empty?

        due_ids = candidates.map(&:first)
        batch_keys = candidates.filter_map(&:last).uniq

        lock_scope = PortalNotificationDelivery.where(id: due_ids)
        lock_scope = lock_scope.or(PortalNotificationDelivery.where(batch_key: batch_keys)) if batch_keys.any?
        locked_rows = lock_scope.order(:id).lock("FOR UPDATE SKIP LOCKED")
          .includes(:user, portal_notification_event: [ :company, :subject ]).to_a

        fresh_rows = locked_rows.select { |row| row.batch_key.nil? && due_row?(row) }
        kept_fresh = fresh_rows.reject { |row| skip_if_ineligible!(row) || retime_and_defer!(row) }
        claimed = claim_fresh_v2_groups(recipient_key, kept_fresh)

        batch_keys.each do |previous_key|
          all_batch_rows = locked_rows.select { |row| row.batch_key == previous_key }
          next if all_batch_rows.empty?
          # If another worker holds a row lock on any sibling in this batch, skip
          # the whole batch rather than partially reconciling it.
          next if all_batch_rows.size < PortalNotificationDelivery.where(batch_key: previous_key).count

          claimed.concat(claim_attempted_batch(recipient_key, previous_key, all_batch_rows))
        end

        claimed
      end
    end

    def claim_fresh_v2_groups(recipient_key, rows, salt: nil)
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
        claim_rows!(ids: ids, key: key, expected_address: group.first.address, recipient_key: recipient_key, legacy_renderer: false)
      end
    end

    def claim_attempted_batch(recipient_key, previous_key, all_batch_rows)
      # Every row in all_batch_rows is already locked FOR UPDATE in ascending id order.
      if (sent_sibling = all_batch_rows.find { |row| row.status == "sent" })
        reconcilable_ids = all_batch_rows.select { |row| row.status == "pending" && !actively_claimed?(row) }.map(&:id)
        mark_reconciled_sent_unclaimed!(reconcilable_ids, sent_sibling) if reconcilable_ids.any?
        return []
      end

      pending_rows = all_batch_rows.select { |row| row.status == "pending" }
      return [] if pending_rows.empty?

      # Wait while any pending sibling is actively claimed by another worker, in
      # retry backoff, or not yet due — never split or race an active batch.
      return [] if pending_rows.any? { |row| !due_row?(row) }

      pending_rows.each { |row| skip_if_ineligible!(row) }
      kept = pending_rows.select { |row| row.status == "pending" }
      return [] if kept.empty?

      other_rows = all_batch_rows.reject { |row| row.status == "pending" }
      all_events = all_batch_rows.map(&:event)

      if other_rows.empty?
        return [ claim_rows!(
          ids: kept.map(&:id).sort,
          key: previous_key,
          expected_address: kept.first.address,
          recipient_key: recipient_key,
          legacy_renderer: !v2_batch_key?(previous_key)
        ) ]
      end

      # Single-company generic v2 batches contain no client/subject/date details
      # and resend their persisted payload verbatim so provider deduplication holds.
      if v2_batch_key?(previous_key) && !Email.payroll_review_batch?(all_events) && all_events.map(&:company_id).uniq.one?
        return [ claim_rows!(
          ids: kept.map(&:id).sort,
          key: previous_key,
          expected_address: kept.first.address,
          recipient_key: recipient_key,
          legacy_renderer: false
        ) ]
      end

      # A v2 batch whose earlier claim crashed before persisting attempted_payload
      # never called the provider, so surviving authorized rows can safely re-key.
      if v2_batch_key?(previous_key) && all_batch_rows.all? { |row| row.attempted_payload.nil? }
        return claim_fresh_v2_groups(recipient_key, kept, salt: "reconciled:#{previous_key}")
      end

      # Authorization changed after an attempt whose provider outcome may be
      # ambiguous: never mint a new idempotency key and resend duplicates.
      mark_revoked_unclaimed!(kept.map(&:id))
      []
    end

    def claim_rows!(ids:, key:, expected_address:, recipient_key:, legacy_renderer:)
      PortalNotificationDelivery.where(id: ids, status: "pending")
        .where("claimed_at IS NULL OR claimed_at < ?", now - CLAIM_TIMEOUT)
        .update_all([ "attempts = attempts + 1, claimed_at = ?, claimed_by = ?, batch_key = ?, updated_at = ?", now, claim_token, key, now ])
      {
        recipient_key: recipient_key,
        key: key,
        ids: ids,
        expected_address: PortalNotificationRecipient.normalize_email(expected_address),
        legacy_renderer: legacy_renderer
      }
    end

    def mark_reconciled_sent_unclaimed!(ids, sent_sibling)
      PortalNotificationDelivery.where(id: ids, status: "pending")
        .where("claimed_at IS NULL OR claimed_at < ?", now - CLAIM_TIMEOUT)
        .update_all(
          status: "sent",
          sent_at: sent_sibling.sent_at || now,
          provider_message_id: sent_sibling.provider_message_id,
          attempted_payload: nil,
          claimed_at: nil,
          claimed_by: nil,
          next_attempt_at: nil,
          last_error_class: nil,
          completed_at: sent_sibling.completed_at || now,
          updated_at: now
        )
    end

    def mark_reconciled_sent_owned!(ids, sent_sibling)
      owned_scope(ids).update_all(
        status: "sent",
        sent_at: sent_sibling.sent_at || now,
        provider_message_id: sent_sibling.provider_message_id,
        attempted_payload: nil,
        claimed_at: nil,
        claimed_by: nil,
        next_attempt_at: nil,
        last_error_class: nil,
        completed_at: sent_sibling.completed_at || now,
        updated_at: now
      )
    end

    def mark_revoked_unclaimed!(ids)
      PortalNotificationDelivery.where(id: ids, status: "pending")
        .where("claimed_at IS NULL OR claimed_at < ?", now - CLAIM_TIMEOUT)
        .update_all(
          status: "skipped",
          skip_reason: "access_revoked",
          attempted_payload: nil,
          claimed_at: nil,
          claimed_by: nil,
          next_attempt_at: nil,
          completed_at: now,
          updated_at: now
        )
    end

    def mark_skipped_owned!(ids, reason)
      owned_scope(ids).update_all(
        status: "skipped",
        skip_reason: reason,
        attempted_payload: nil,
        claimed_at: nil,
        claimed_by: nil,
        next_attempt_at: nil,
        completed_at: now,
        updated_at: now
      )
    end

    def owned_scope(ids)
      PortalNotificationDelivery.where(id: ids, status: "pending", claimed_by: claim_token, claimed_at: now)
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

      current_mode = Preferences.mode_for(user, row.event.preference_category)
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

    def skip_if_ineligible!(row, expected_address: nil, require_claim: false)
      reason = skip_reason_for(row, expected_address: expected_address)
      return false unless reason

      if require_claim
        updated = owned_scope([ row.id ]).update_all(
          status: "skipped", skip_reason: reason, attempted_payload: nil, claimed_at: nil, claimed_by: nil, completed_at: now, updated_at: now
        )
        row.assign_attributes(status: "skipped", skip_reason: reason, attempted_payload: nil, claimed_at: nil, claimed_by: nil, completed_at: now) if updated.positive?
      else
        row.update!(status: "skipped", skip_reason: reason, attempted_payload: nil, claimed_at: nil, claimed_by: nil, completed_at: now)
      end
      if reason == "foreign_account_suppressed"
        Rails.logger.info("[PortalNotification] foreign account suppressed delivery=#{row.id} company=#{row.company_id}")
      end
      true
    end

    def skip_reason_for(row, expected_address: nil)
      event = row.event
      return "email_delivery_disabled" unless PortalNotifications.delivery_enabled?
      return "email_not_configured" unless Transport.configured?
      return "resource_unavailable" unless Recipients.subject_available?(event)
      return "destination_changed" if destination_changed?(row, expected_address: expected_address)

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
      return "preference_off" if Preferences.mode_for(user, event.preference_category) == "off"
      # Reading the conversation first makes a still-pending alert unnecessary.
      return "already_read" if event.message_event? && !event.subject.unread_for?(user)

      nil
    end

    # Rows whose destination email changed after enqueue, claim, or first
    # attempt are deliberately dropped (skipped as destination_changed) rather
    # than resent to either the old or new mailbox.
    def destination_changed?(row, expected_address: nil)
      current_address = PortalNotificationRecipient.normalize_email(row.address)
      return true if current_address.blank?
      return true if row.intended_recipient_email.present? && current_address != PortalNotificationRecipient.normalize_email(row.intended_recipient_email)
      return true if expected_address.present? && current_address != PortalNotificationRecipient.normalize_email(expected_address)
      if row.attempted_payload.present? && row.attempted_payload["to"].present? &&
          current_address != PortalNotificationRecipient.normalize_email(row.attempted_payload["to"])
        return true
      end

      false
    end

    # Re-locks the full batch in ascending id order, revalidates every row from
    # fresh DB state, snapshots attempted_payload before first send, and commits
    # BEFORE performing the outbound HTTP call.
    #
    # A narrow race window remains between committing this pre-send transaction
    # and the provider HTTP request; DB locks are intentionally NOT held across
    # network I/O so provider latency cannot stall database workers.
    def deliver_claimed(group)
      prepared = prepare_delivery(group)
      return false unless prepared

      deliver(prepared)
    rescue StandardError => error
      record_failure!(group, error)
      false
    end

    def prepare_delivery(group)
      PortalNotificationDelivery.transaction do
        all_batch_rows = PortalNotificationDelivery.where(batch_key: group.fetch(:key))
          .order(:id).lock("FOR UPDATE")
          .includes(:user, portal_notification_event: [ :company, :subject ]).to_a
        owned_rows = all_batch_rows.select do |row|
          group.fetch(:ids).include?(row.id) && row.status == "pending" &&
            row.claimed_by == claim_token && row.claimed_at == now
        end
        return nil if owned_rows.empty?

        if (sent_sibling = all_batch_rows.find { |row| row.status == "sent" })
          mark_reconciled_sent_owned!(owned_rows.map(&:id), sent_sibling)
          return nil
        end

        owned_rows.each do |row|
          skip_if_ineligible!(row, expected_address: group[:expected_address], require_claim: true)
        end
        kept = owned_rows.select { |row| row.status == "pending" }
        return nil if kept.empty?

        kept_ids = kept.map(&:id).sort
        other_rows = all_batch_rows.reject { |row| kept_ids.include?(row.id) }
        all_events = all_batch_rows.map(&:event)
        final_key = group.fetch(:key)

        if other_rows.any?
          single_company_generic_v2 = v2_batch_key?(final_key) &&
            !Email.payroll_review_batch?(all_events) &&
            all_events.map(&:company_id).uniq.one?

          if !single_company_generic_v2
            # A v2 batch with no persisted attempted_payload on any row never
            # reached the provider (even after a crashed claim with attempts > 1).
            never_sent = v2_batch_key?(final_key) && all_batch_rows.all? { |row| row.attempted_payload.nil? }
            if never_sent
              # Provider has never been called for this batch yet: reconcile onto
              # a fresh key containing ONLY the freshly authorized rows.
              first = kept.first
              destination = Email.destination_group(first.event, delivery_mode: first.delivery_mode)
              final_key = v2_batch_key(
                recipient_key: group.fetch(:recipient_key),
                mode: first.delivery_mode,
                destination: destination,
                company_id: first.company_id,
                demo: first.event.company&.demo? == true,
                ids: kept_ids,
                salt: "reconciled:#{final_key}"
              )
              owned_scope(kept_ids).update_all(batch_key: final_key, updated_at: now)
              all_batch_rows = kept
              all_events = kept.map(&:event)
            else
              mark_skipped_owned!(kept_ids, "access_revoked")
              return nil
            end
          end
        end

        first = kept.first
        fresh_address = first.address
        persisted = kept.filter_map(&:attempted_payload).first || all_batch_rows.filter_map(&:attempted_payload).first
        payload = if persisted.present?
          if PortalNotificationRecipient.normalize_email(persisted["to"]) != PortalNotificationRecipient.normalize_email(fresh_address)
            mark_skipped_owned!(kept_ids, "destination_changed")
            return nil
          end
          persisted.symbolize_keys
        else
          legacy = group.fetch(:legacy_renderer, false)
          events_for_render = kept.map(&:event)
          app_user = legacy ? first.user_id.present? : effective_user_for(first).present?
          email = Email.new(
            audience: first.event.audience,
            delivery_mode: first.delivery_mode,
            events: events_for_render,
            app_user: app_user,
            legacy_renderer: legacy
          )
          rendered = email.payload(from: Transport.from_email, to: fresh_address)
          kept.each { |row| row.update!(attempted_payload: rendered) if row.attempted_payload.nil? }
          rendered
        end

        {
          ids: kept_ids,
          key: final_key,
          audience: first.event.audience,
          payload: payload,
          demo_company: kept.map { |row| row.event.company }.find { |company| company&.demo? }
        }
      end
    end

    def deliver(group)
      payload = group[:payload] || begin
        email = Email.new(
          audience: group.fetch(:audience),
          delivery_mode: group.fetch(:mode),
          events: group.fetch(:events),
          app_user: group.fetch(:app_user) { group.fetch(:user).present? },
          legacy_renderer: group.fetch(:legacy_renderer, false)
        )
        email.payload(from: Transport.from_email, to: group.fetch(:address))
      end
      demo_company = group.key?(:demo_company) ? group[:demo_company] : group.fetch(:events).map(&:company).find { |company| company&.demo? }
      # An employee alert is rechecked at the transport against the demo's
      # employee app too (the demo kill switch may have run since the claim).
      response = DemoOutbound.scoped(demo_company, channel: channel_for(group.fetch(:audience))) do
        Transport.deliver(payload, idempotency_key: group.fetch(:key))
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
      owned_scope(group[:ids]).update_all(
        attributes.merge(attempted_payload: nil, claimed_at: nil, claimed_by: nil, next_attempt_at: nil, last_error_class: nil, completed_at: now, updated_at: now))
    end

    # Only the error class is kept or logged: provider messages can echo
    # recipients or payload content.
    def record_failure!(group, error)
      owned_scope(group[:ids]).find_each do |row|
        if row.attempts >= MAX_ATTEMPTS
          owned_scope([ row.id ]).update_all(
            status: "failed", attempted_payload: nil, claimed_at: nil, claimed_by: nil, next_attempt_at: nil,
            last_error_class: error.class.name, completed_at: now, updated_at: now
          )
        else
          owned_scope([ row.id ]).update_all(
            claimed_at: nil, claimed_by: nil, next_attempt_at: now + RETRY_BACKOFF.fetch(row.attempts - 1),
            last_error_class: error.class.name, updated_at: now
          )
        end
      end
      Rails.logger.warn("[PortalNotification] delivery failed batch=#{group[:key]} error=#{error.class.name}")
    end
  end
end
