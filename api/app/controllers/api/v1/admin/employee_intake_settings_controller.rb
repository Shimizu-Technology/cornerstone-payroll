# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeIntakeSettingsController < BaseController
        def show
          render json: { data: EmployeeIntakePolicy.settings(current_company, current_user) }
        end

        def update
          return render json: { error: "Organization administrator access required" }, status: :forbidden unless current_user.organization_admin?

          attrs = params.require(:employee_intake_settings).permit(:enabled, :reason, :expires_at)
          enabled = ActiveModel::Type::Boolean.new.cast(attrs[:enabled])
          reason = attrs[:reason].to_s.strip
          expires_at = Time.iso8601(attrs[:expires_at].to_s) if enabled
          if enabled && (reason.blank? || expires_at <= Time.current || expires_at > Time.current + EmployeeIntakePolicy::MAX_WINDOW)
            return render json: { error: "Provide a reason and an expiration within the next 24 hours" }, status: :unprocessable_entity
          end
          current_company.with_lock do
            current_company.update!(employee_intake_expires_at: enabled ? expires_at : nil,
              employee_intake_reason: enabled ? reason : current_company.employee_intake_reason,
              employee_intake_enabled_by_id: enabled ? current_user.id : current_company.employee_intake_enabled_by_id)
            AuditLog.record!(user: current_user, company_id: current_company.id,
              action: "employee_intake_settings#update", record_type: "companies", record_id: current_company.id,
              metadata: { enabled: enabled, reason: reason, expires_at: expires_at })
          end
          render json: { data: EmployeeIntakePolicy.settings(current_company, current_user) }
        rescue ArgumentError
          render json: { error: "Provide a valid expiration date and time" }, status: :unprocessable_entity
        end
      end
    end
  end
end
