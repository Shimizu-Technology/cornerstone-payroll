# frozen_string_literal: true

module PayrollAccess
  class SessionRevoker
    class << self
      def disconnect_user(user)
        # The native internal channel is user-scoped, independent of assignments
        # or companies retained by existing sockets. One broadcast reaches every
        # matching connection across servers; adapter failures remain retryable.
        ActionCable.server.remote_connections.where(current_user: user).disconnect(reconnect: false)
      end
    end
  end
end
