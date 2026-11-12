# frozen_string_literal: true

module Api
  module V1
    # Personal portal email alert settings for staff and client portal users.
    # Organization admins also see clients whose recent portal work had nobody
    # on staff to notify.
    class NotificationSettingsController < ApplicationController
      RECENT_LIMIT = 20
      WARNING_WINDOW = 30.days
      WARNING_LIMIT = 50

      before_action :require_portal_user!

      def show
        render json: { data: settings_payload }
      end

      def update
        PortalNotificationPreference.transaction do
          changes = PortalNotifications::Preferences.update!(current_user, preference_params)
          if changes.any?
            AuditLog.record!(user: current_user, company_id: nil, organization_id: current_user.organization_id,
              action: "notification_settings#update", record_type: "users", record_id: current_user.id,
              subject_name: current_user.name, metadata: { changes: changes })
          end
        end
        render json: { data: settings_payload }
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def require_portal_user!
        return if current_user && PortalNotifications::Preferences.audience_for(current_user)

        render json: { error: "Portal notification settings are not available for this account" }, status: :forbidden
      end

      def preference_params
        raw = params[:preferences]
        raise ArgumentError, "Choose a setting for each alert type" unless raw.is_a?(ActionController::Parameters)

        unknown = raw.keys - PortalNotifications::CATEGORIES.keys
        raise ArgumentError, "Unknown notification category" if unknown.any?

        raw.permit(*PortalNotifications::CATEGORIES.keys).to_h
      end

      def settings_payload
        modes = PortalNotifications::Preferences.modes_for(current_user)
        payload = {
          email_delivery_enabled: PortalNotifications.delivery_enabled?,
          digest_time_label: PortalNotifications::DIGEST_TIME_LABEL,
          categories: PortalNotifications::Preferences.categories_for(current_user).map do |key, category|
            { key: key, label: category[:label], description: category[:description],
              delivery_mode: modes.fetch(key), default_mode: category[:default_mode] }
          end,
          recent_alerts: recent_alerts
        }
        payload[:administration] = administration_payload if current_user.organization_admin?
        payload
      end

      # Generic labels only; the person can open the item itself in the portal.
      def recent_alerts
        deliveries = current_user.portal_notification_deliveries.recent_first.limit(RECENT_LIMIT)
          .includes(:company, :portal_notification_event).to_a
        deliveries.map do |delivery|
          event = delivery.event
          {
            id: delivery.id, category: event.category,
            label: PortalNotifications::CATEGORIES.dig(event.category, :label),
            company_name: current_user.can_access_company?(delivery.company_id) ? delivery.company.name : nil,
            status: delivery.status, delivery_mode: delivery.delivery_mode, skip_reason: delivery.skip_reason,
            occurred_at: event.occurred_at, deliver_after: delivery.deliver_after, sent_at: delivery.sent_at,
            attempts: delivery.attempts
          }
        end
      end

      def administration_payload
        warnings = PortalNotificationEvent.without_staff_recipients
          .where(organization_id: current_user.organization_id).where("occurred_at > ?", WARNING_WINDOW.ago)
          .group(:company_id).order(Arel.sql("MAX(occurred_at) DESC")).limit(WARNING_LIMIT)
          .pluck(:company_id, Arel.sql("COUNT(*)"), Arel.sql("MAX(occurred_at)"))
        names = Company.where(id: warnings.map(&:first)).pluck(:id, :name).to_h
        {
          clients_without_recipients: warnings.map do |company_id, count, last_at|
            { company_id: company_id, company_name: names[company_id], event_count: count, last_occurred_at: last_at }
          end
        }
      end
    end
  end
end
