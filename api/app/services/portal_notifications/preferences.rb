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
        CATEGORIES.select { |_key, category| category[:audience] == audience }
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
            changes[category] = [ before, mode ]
          end
        end
        changes
      end
    end
  end
end
