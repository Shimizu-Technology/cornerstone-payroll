# frozen_string_literal: true

module Api
  module V1
    module Admin
      class FilingSubmittersController < BaseController
        def show
          profile = FilingSubmitter.find_or_initialize_by(organization_id: current_company.organization_id)
          render json: { profile: profile.attributes.slice(*FilingSubmitter::FIELDS.map(&:to_s)), missing_fields: profile.missing_fields, can_edit: current_user.organization_admin? }
        end

        def update
          return render json: { error: "Organization admin access required" }, status: :forbidden unless current_user.organization_admin?

          profile = FilingSubmitter.find_or_initialize_by(organization_id: current_company.organization_id)
          profile.update!(params.require(:profile).permit(*FilingSubmitter::FIELDS))
          show
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.join("; ") }, status: :unprocessable_entity
        end
      end
    end
  end
end
