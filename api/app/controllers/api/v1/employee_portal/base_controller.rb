# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      class BaseController < ActionController::API
        before_action :require_employee_link!

        private

        def require_employee_link!
          link_id = request.headers["X-Employee-Link-Id"]
          token = request.headers["Authorization"].to_s[/\ABearer (\S+)\z/, 1]
          unless token && link_id&.match?(/\A[1-9]\d{0,18}\z/) && link_id.to_i <= 2**63 - 1
            return head :not_found
          end

          subject = ClerkTokenVerifier.new.verify(token)&.fetch("sub", nil)
          return head :not_found unless subject.is_a?(String) && subject.present? && !subject.start_with?("pending_")

          user = User.find_by(clerk_id: subject)
          return head :not_found unless user && StagingOutboundPolicy.tester?(user_id: user.id, email: user.email, id: subject)
          return head :not_found unless user.payroll_access_allowed?

          @employee_link = user.employee_account_links.portal_eligible.find_by(id: link_id)
          head :not_found unless @employee_link&.portal_enabled?
        end
      end
    end
  end
end
