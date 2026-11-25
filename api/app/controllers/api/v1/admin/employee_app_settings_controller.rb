# frozen_string_literal: true

module Api
  module V1
    module Admin
      # The selected client's employee-app branding and Help contacts.
      # Viewing and changing both require client administration for the client.
      class EmployeeAppSettingsController < BaseController
        include EmployeeAppSettingsActions

        # PATCH w2_delivery { w2_delivery: "mailed" | "handed_out" | null }:
        # how this client's paper W-2s reach employees (M4-5). Staff only; the
        # employee app says "Your W-2 will be mailed here" only when mailed.
        def update_w2_delivery
          value = params[:w2_delivery].presence
          unless value.nil? || Company::W2_DELIVERY_OPTIONS.include?(value)
            return render json: { error: "Choose mailed, handed out, or not set" }, status: :unprocessable_entity
          end

          skip_default_audit_log!
          current_company.with_lock do
            revalidate_settings_write_access!
            before = { "w2_delivery" => current_company.w2_delivery }
            current_company.update!(w2_delivery: value)
            record_settings_audit!("employee_app_settings#update_w2_delivery", before, { "w2_delivery" => value })
          end
          render json: { data: settings_payload }
        end

        private

        def revalidate_settings_write_access!
          revalidate_current_company_write_access!(capability: :manage_client_administration)
        end
      end
    end
  end
end
