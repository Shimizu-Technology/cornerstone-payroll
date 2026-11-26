# frozen_string_literal: true

module Api
  module V1
    module Admin
      class FilingSubmittersController < BaseController
        def show
          profile = FilingSubmitter.find_or_initialize_by(organization_id: current_company.organization_id)
          render json: {
            exists: profile.persisted?,
            profile: profile.attributes.slice(*FilingSubmitter::FIELDS.map(&:to_s)),
            missing_fields: profile.missing_fields,
            problems: profile.filing_problems,
            can_edit: !current_company&.contained? && StaffRolePolicy.allowed?(current_user, :manage_organization)
          }
        end

        def update
          return render json: { error: "Organization admin access required" }, status: :forbidden unless StaffRolePolicy.allowed?(current_user, :manage_organization)

          profile = find_or_create_profile
          profile.update!(params.require(:profile).permit(*FilingSubmitter::FIELDS))
          show
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join("; ") }, status: :unprocessable_entity
        end

        private

        def find_or_create_profile
          organization_id = current_company.organization_id
          FilingSubmitter.find_by(organization_id: organization_id) || FilingSubmitter.create_or_find_by!(organization_id: organization_id)
        rescue ActiveRecord::RecordInvalid
          # A concurrent insert may be visible to the uniqueness validator
          # before PostgreSQL gets the chance to raise RecordNotUnique.
          FilingSubmitter.find_by(organization_id: organization_id) || raise
        end
      end
    end
  end
end
