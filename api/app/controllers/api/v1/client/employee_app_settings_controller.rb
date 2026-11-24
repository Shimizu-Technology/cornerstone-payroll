# frozen_string_literal: true

module Api
  module V1
    module Client
      # The client's own users set how the employee app looks and who their
      # employees can ask for help, for the companies they have access to.
      class EmployeeAppSettingsController < BaseController
        include EmployeeAppSettingsActions

        class ClientAccessChanged < StandardError; end
        rescue_from ClientAccessChanged do
          render json: { error: "Your access to this company has changed. Your changes were not saved." }, status: :forbidden
        end

        private

        # Inside the company lock, re-read the user so a removed or deactivated
        # client user can't finish a save that started before the change.
        def revalidate_settings_write_access!
          actor = User.lock.find_by(id: current_user&.id)
          allowed = actor&.active? && actor.client? && actor.payroll_access_allowed? && actor.can_access_company?(current_company.id)
          raise ClientAccessChanged unless allowed
        end
      end
    end
  end
end
