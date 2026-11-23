# frozen_string_literal: true

module Api
  module V1
    class CableTicketsController < ApplicationController
      include ExplicitCompanyAccess

      def create
        unless current_user&.can_access_company?(current_company_id)
          return render json: { error: "You do not have access to this company" }, status: :forbidden
        end

        render json: {
          ticket: CableTicketService.issue!(
            user: current_user, company_id: current_company_id,
            clerk_token_payload: @clerk_token_payload, request: request, auth_disabled: auth_disabled?
          ),
          expires_in: CableTicketService::TTL.to_i
        }, status: :created
      end
    end
  end
end
