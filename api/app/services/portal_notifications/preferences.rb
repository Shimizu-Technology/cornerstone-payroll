# frozen_string_literal: true

module PortalNotifications
  module Preferences
    class << self
      def audience_for(user)
        if user&.client? then "client"
        elsif user&.staff_member? then "staff"
        end
      end

      def categories_for(user)
        audience = audience_for(user)
        categories = CATEGORIES.select { |_key, category| category[:audience] == audience }
        return categories unless audience == "client"

        enabled = Company.where(id: user.accessible_company_ids).any? do |company|
          CompanyFeatures.for(company).employee_portal_feature?(:profile_requests)
        end
        enabled ? categories : categories.except("address_approvals", "contact_changes")
      end

      def mode_for(user, category)
        PortalNotificationPreference.where(user_id: user.id, category: category).pick(:delivery_mode) ||
          CATEGORIES.fetch(category).fetch(:default_mode)
      end

      def modes_for(user)
        saved = PortalNotificationPreference.where(user_id: user.id).pluck(:category, :delivery_mode).to_h
        categories_for(user).to_h { |key, category| [ key, saved[key] || category[:default_mode] ] }
      end

      # Returns { category => [before, after] } for changed categories only.
      def update!(user, requested)
        allowed = categories_for(user)
        unknown = requested.keys.map(&:to_s) - allowed.keys
        raise ArgumentError, "Unknown notification category" if unknown.any?

        changes = {}
        PortalNotificationPreference.transaction do
          # Serializes saves for one person, so two first saves of the same
          # category cannot both insert and collide on the unique index.
          User.lock.find(user.id)
          requested.each do |category, mode|
            category = category.to_s
            mode = mode.to_s
            raise ArgumentError, "Choose immediate, daily digest or off" unless PortalNotificationPreference::MODES.include?(mode)

            preference = PortalNotificationPreference.find_or_initialize_by(user_id: user.id, category: category)
            before = preference.delivery_mode || allowed.dig(category, :default_mode)
            next if before == mode

            preference.update!(delivery_mode: mode)
            retime_pending_deliveries!(user, category, mode)
            changes[category] = [ before, mode ]
          end
        end
        changes
      end

      # Switching Immediate <-> Digest retimes unattempted queued alerts so the
      # change takes effect for already-queued notifications too. Because this
      # runs in system RLS scope, address-based matches are strictly limited to
      # active companies in the user's own organization where this user is an
      # eligible recipient, and the update is conditional so it cannot race a
      # concurrent dispatcher claim.
      def retime_pending_deliveries!(user, category, mode)
        return unless PortalNotificationDelivery::DELIVERY_MODES.include?(mode)

        accessible_company_ids = Company.active
          .where(organization_id: user.organization_id, id: user.accessible_company_ids)
          .where("payroll_environment = 'live' OR test_workspace_purpose = 'demo'")
          .pluck(:id)
        return if accessible_company_ids.empty?

        base = PortalNotificationDelivery.pending
          .joins(:portal_notification_event)
          .where(
            company_id: accessible_company_ids,
            attempts: 0,
            claimed_at: nil,
            batch_key: nil,
            portal_notification_events: { organization_id: user.organization_id, category: category }
          )

        canonical_email = PortalNotificationRecipient.canonical_email(user.email)
        staff_address_match = user.staff_member? && user.payroll_access_allowed? &&
          StaffRolePolicy.allowed?(user, :staff_workspace) && canonical_email.present?
        scope = if staff_address_match
          local, domain = canonical_email.split("@", 2)
          email_scope = if domain == "gmail.com"
            base.where(user_id: nil).where(
              "LOWER(SPLIT_PART(BTRIM(recipient_email), '@', 2)) IN ('gmail.com', 'googlemail.com') AND " \
              "REPLACE(SPLIT_PART(LOWER(SPLIT_PART(BTRIM(recipient_email), '@', 1)), '+', 1), '.', '') = ?",
              local
            )
          else
            base.where(user_id: nil).where("LOWER(BTRIM(recipient_email)) = ?", canonical_email)
          end
          base.where(user_id: user.id).or(email_scope)
        else
          base.where(user_id: user.id)
        end

        scope.includes(:portal_notification_event).find_each do |delivery|
          if delivery.user_id.nil? &&
              Recipients.eligible_account_user_for_email(delivery.recipient_email, delivery.event)&.id != user.id
            next
          end

          deliver_after = PortalNotifications.deliver_after_for(mode, delivery.event.occurred_at)
          next if delivery.delivery_mode == mode && delivery.deliver_after == deliver_after

          PortalNotificationDelivery.where(
            id: delivery.id,
            company_id: delivery.company_id,
            status: "pending",
            attempts: 0,
            claimed_at: nil,
            batch_key: nil
          ).update_all(delivery_mode: mode, deliver_after: deliver_after, updated_at: Time.current)
        end
      end
    end
  end
end
