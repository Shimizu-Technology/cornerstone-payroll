# frozen_string_literal: true

module Api
  module V1
    module Admin
      class ClientOperatingProfilesController < BaseController
        before_action :load_and_authorize_target_company!

        # GET /api/v1/admin/companies/:company_id/operating_profile?on=YYYY-MM-DD
        def show
          as_of = parse_as_of_date
          return unless as_of

          features = CompanyFeatures.for(@target_company, on: as_of)
          history = @target_company.client_operating_profiles.history_order.map(&:serialize_payload)

          render json: {
            as_of: as_of.iso8601,
            effective: serialize_effective(features),
            history: history,
            catalog: OperatingProfileCatalog.serialize,
            editable_keys: OperatingProfileCatalog.editable_keys_for(user: current_user, company: @target_company)
          }
        end

        private

        def audit_company_id
          @target_company&.id || super
        end

        def load_and_authorize_target_company!
          raw_company_id = params[:company_id].to_s
          unless raw_company_id.match?(/\A[1-9]\d*\z/)
            return render json: { error: "Company not found" }, status: :not_found
          end

          @target_company = Company.find_by(id: raw_company_id.to_i)
          unless @target_company
            return render json: { error: "Company not found" }, status: :not_found
          end

          unless current_user&.can_access_company?(@target_company.id)
            return render json: { error: "You do not have access to this company" }, status: :forbidden
          end

          return unless @target_company.test_workspace?

          unless TestWorkspaceAccessPolicy.allowed?(
            user: current_user,
            company: @target_company,
            request_method: request.request_method,
            capability: StaffRolePolicy.capability_for(controller_path: controller_path, action_name: action_name),
            controller_path: controller_path,
            action_name: action_name
          )
            return render json: { error: "Your test workspace access does not allow this action" }, status: :forbidden
          end

          return if @target_company.migration_rehearsal_status == "ready"

          render json: {
            error: "This test workspace is still being prepared. Try again after its verified copy is ready."
          }, status: :conflict
        end

        def parse_as_of_date
          return PayrollBusinessClock.today if params[:on].blank?

          raw = params[:on].to_s.strip
          unless raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)
            render json: { error: "Invalid date parameter 'on'. Expected YYYY-MM-DD." }, status: :unprocessable_entity
            return nil
          end

          Date.iso8601(raw)
        rescue Date::Error
          render json: { error: "Invalid date parameter 'on'. Expected YYYY-MM-DD." }, status: :unprocessable_entity
          nil
        end

        def serialize_effective(features)
          payload = features.profile.serialize_payload
          return payload unless @target_company.test_workspace?

          payload.merge(
            employee_portal_enabled: features.employee_portal_enabled?,
            options: payload.fetch(:options).merge("subdomain_enabled" => features.subdomain_enabled?)
          )
        end
      end
    end
  end
end
