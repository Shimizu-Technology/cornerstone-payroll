# frozen_string_literal: true

module Api
  module V1
    module Admin
      class AnnualRetirementLimitsController < BaseController
        before_action :require_platform_admin!, only: [ :create, :update ]

        def index
          render json: { data: AnnualRetirementLimit.order(tax_year: :desc).as_json,
            can_manage: current_user.super_admin? && !current_company&.test_workspace? }
        end

        def create
          save_limit(AnnualRetirementLimit.new, :created)
        end

        def update
          limit = AnnualRetirementLimit.find_by(id: params[:id])
          return render json: { error: "Retirement limits not found" }, status: :not_found unless limit

          save_limit(limit, :ok)
        end

        private

        def require_platform_admin!
          render json: { error: "Only a platform administrator can change shared annual retirement limits" }, status: :forbidden unless current_user.super_admin?
        end

        def save_limit(limit, status)
          values = limit_params
          reason = values.delete(:reason).to_s.strip
          return render json: { error: "Explain the source and reason for this limit change" }, status: :unprocessable_entity if reason.blank?
          if values[:annual_additions_limit].blank? || values[:compensation_limit].blank?
            return render json: { error: "Annual additions and compensation limits are required" }, status: :unprocessable_entity
          end
          AnnualRetirementLimit.transaction do
            limit.lock! if limit.persisted?
            before_values = limit.attributes.slice(*values.keys.map(&:to_s))
            limit.update!(values)
            AuditLog.record!(user: current_user, company_id: nil, organization_id: current_user.organization_id,
              action: "annual_retirement_limits##{action_name}", record_type: "AnnualRetirementLimit",
              record_id: limit.id, subject_name: "#{limit.tax_year} retirement limits",
              metadata: { reason: reason, before_values: before_values,
                after_values: limit.attributes.slice(*values.keys.map(&:to_s)) })
          end
          render json: { data: limit.as_json }, status: status
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        end

        def limit_params
          params.require(:annual_retirement_limit).permit(:tax_year, :elective_deferral_limit,
            :catch_up_limit, :enhanced_catch_up_limit, :roth_catch_up_wage_threshold,
            :annual_additions_limit, :compensation_limit, :source_name, :source_url, :reason)
        end
      end
    end
  end
end
