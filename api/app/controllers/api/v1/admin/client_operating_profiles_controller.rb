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

          render json: profile_payload(as_of)
        end

        def update
          profile = ClientOperatingProfiles::UpdateService.new(
            company: @target_company,
            actor: current_user,
            effective_on: params[:effective_on],
            changes: params[:changes].try(:to_unsafe_h),
            reason: params[:reason],
            lock_version: params[:lock_version]
          ).call

          render json: profile_payload(PayrollBusinessClock.today).merge(saved: serialize_profile(profile))
        rescue ClientOperatingProfiles::UpdateService::Forbidden => error
          render json: { error: error.message }, status: :forbidden
        rescue ClientOperatingProfiles::UpdateService::Conflict, ActiveRecord::StaleObjectError => error
          render json: { error: error.message }, status: :conflict
        rescue ClientOperatingProfiles::UpdateService::Invalid, ActiveRecord::RecordInvalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def activate_lifecycle_mode
          unless StaffRolePolicy.allowed?(current_user, :manage_organization)
            return render json: { error: StaffRolePolicy.error_message(:manage_organization) }, status: :forbidden
          end

          if lifecycle_mode_locked?
            return render json: { error: "Employee lifecycle mode is locked until its milestone launches." }, status: :unprocessable_entity
          end

          result = ClientOperatingProfiles::LifecycleModeActivationService.activate!(
            company: @target_company,
            actor: current_user
          )
          case result.status
          when :activated, :already_active
            render json: profile_payload(PayrollBusinessClock.today).merge(
              activation_status: result.status.to_s,
              saved: serialize_profile(result.profile)
            )
          when :blocked
            render json: {
              error: result.preflight.error_messages.join(" "),
              blockers: result.preflight.blockers_hash,
              errors: result.preflight.error_messages,
              lifecycle_mode_activation_status: "blocked"
            }, status: :unprocessable_entity
          else
            render json: { error: "No scheduled Client-managed lifecycle mode is due for activation." }, status: :unprocessable_entity
          end
        end

        private

        def rls_company_id
          raw_id = params[:company_id].to_s
          return unless raw_id.match?(/\A[1-9]\d{0,18}\z/) && raw_id.to_i <= 2**63 - 1

          raw_id if current_user&.can_access_company?(raw_id.to_i)
        end

        def profile_payload(as_of)
          features = CompanyFeatures.for(@target_company, on: as_of)
          profiles = @target_company.client_operating_profiles.history_order.to_a

          {
            as_of: as_of.iso8601,
            effective: serialize_profile(features.profile),
            history: profiles.map { |profile| serialize_profile(profile) },
            lock_version: profiles.first&.lock_version || 0,
            available_effective_dates: ClientOperatingProfiles::EffectiveDates.new(company: @target_company, latest: profiles.first).available.map(&:iso8601),
            catalog: OperatingProfileCatalog.serialize,
            client_name: @target_company.name,
            offering_presets: OperatingProfileCatalog::OFFERING_PRESETS,
            locked_keys: OperatingProfileCatalog.locked_keys,
            connected_source_active: @target_company.time_tracking_sources.active.where(source_type: "aire_services").exists?,
            editable_keys: OperatingProfileCatalog.editable_keys_for(user: current_user, company: @target_company),
            employee_lifecycle_preflight: lifecycle_mode_locked? ? nil : ClientOperatingProfiles::LifecycleModePreflight.summary_for(@target_company, as_of: as_of)
          }
        end

        def lifecycle_mode_locked?
          CompanyFeatures::LOCKED_OFF.include?("client_portal.employee_lifecycle_mode")
        end

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

          header_company_id = request.headers["X-Company-Id"].presence
          if header_company_id.present? && header_company_id.to_i != @target_company.id
            return render json: { error: "Company context does not match the requested client" }, status: :forbidden
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
            return render json: { error: @target_company.demo? ? Company::DEMO_ACCESS_DENIED_MESSAGE : "Your test workspace access does not allow this action" }, status: :forbidden
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

        # A practice copy never opens the employee app; a demo company reports
        # its real switches, like a live client (CompanyFeatures).
        def serialize_profile(profile)
          payload = profile.serialize_payload
          return payload unless @target_company.practice_copy?

          payload.merge(
            employee_portal_enabled: false,
            options: payload.fetch(:options).merge("subdomain_enabled" => false)
          )
        end
      end
    end
  end
end
