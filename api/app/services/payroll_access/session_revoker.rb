# frozen_string_literal: true

module PayrollAccess
  class SessionRevoker
    class << self
      def disconnect_user(user)
        ActionCable.server.remote_connections
          .where(current_user: user)
          .disconnect(reconnect: false)
      end
    end
  end
end
