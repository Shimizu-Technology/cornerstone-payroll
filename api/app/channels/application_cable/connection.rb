# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :current_company

    def connect
      self.current_user = find_verified_user
      self.current_company = resolve_company
    end

    private

    def find_verified_user
      if auth_disabled?
        preferred = User.includes(:organization).where(role: %w[super_admin admin org_admin]).find(&:payroll_access_allowed?)
        return preferred || User.includes(:organization).find(&:payroll_access_allowed?) || reject_unauthorized_connection
      end

      payload = cable_ticket_payload
      user = User.find_by(id: payload&.dig("user_id"))
      reject_unauthorized_connection unless user&.payroll_access_allowed?

      user
    end

    def resolve_company
      company_id = cable_ticket_payload&.dig("company_id")
      company_id ||= current_user.company_id

      reject_unauthorized_connection unless current_user.payroll_access_allowed?
      reject_unauthorized_connection unless current_user.can_access_company?(company_id)

      Company.find(company_id)
    end

    def cable_ticket_payload
      @cable_ticket_payload ||= CableTicketService.consume(request.params[:ticket])
    end

    def auth_disabled?
      return false if Rails.env.production?

      ENV["AUTH_ENABLED"] != "true"
    end
  end
end
