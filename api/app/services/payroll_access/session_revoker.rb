# frozen_string_literal: true

module PayrollAccess
  class SessionRevoker
    class << self
      def disconnect_user(user)
        ActionCable.server.remote_connections
          .where(current_user: user)
          .disconnect(reconnect: false)
      rescue StandardError => e
        Rails.logger.error(
          "[SessionRevoker] Failed to disconnect cable sessions for user=#{user.id}: #{e.class}: #{e.message}"
        )
        false
      end
    end
  end
end
