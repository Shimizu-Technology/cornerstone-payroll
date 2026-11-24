# frozen_string_literal: true

module Api
  module V1
    module Admin
      # The selected client's employee-app branding and Help contacts.
      # Viewing and changing both require client administration for the client.
      class EmployeeAppSettingsController < BaseController
        include EmployeeAppSettingsActions

        private

        def revalidate_settings_write_access!
          revalidate_current_company_write_access!(capability: :manage_client_administration)
        end
      end
    end
  end
end
