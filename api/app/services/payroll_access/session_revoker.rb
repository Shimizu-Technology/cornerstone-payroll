# frozen_string_literal: true

module PayrollAccess
  class SessionRevoker
    class << self
      def disconnect_user(user)
        connections = ActionCable.server.remote_connections
        # Cover user-only channels retained from an older connection contract.
        connections.where(current_user: user, current_company: nil).disconnect(reconnect: false)
        # Current access cannot describe every still-open connection: roles,
        # assignments and company activity may have changed since it connected.
        Company.unscoped.select(:id).find_each do |company|
          connections.where(current_user: user, current_company: company).disconnect(reconnect: false)
        end
      end
    end
  end
end
