# frozen_string_literal: true

module Api
  module V1
    module Admin
      class UserInvitationsController < BaseController
        before_action :require_admin!

        # POST /api/v1/admin/user_invitations
        def create
          if User.where(company_id: current_company_id, email: invitation_params[:email]).exists?
            return render json: { error: "User already exists" }, status: :unprocessable_entity
          end

          invitation = UserInvitation.create!(
            company_id: current_company_id,
            invited_by_id: current_user_id,
            email: invitation_params[:email],
            name: invitation_params[:name],
            role: invitation_params[:role],
            token: SecureRandom.hex(32),
            invited_at: Time.current,
            expires_at: 7.days.from_now
          )

          invite_url = "#{frontend_url}/invite?token=#{invitation.token}"
          UserInvitationMailer.invite_email(invitation, invite_url)

          render json: {
            data: {
              id: invitation.id,
              email: invitation.email,
              role: invitation.role,
              invited_at: invitation.invited_at,
              expires_at: invitation.expires_at,
              invite_url: invite_url
            }
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def invitation_params
          params.require(:invitation).permit(:email, :name, :role)
        end

        def frontend_url
          ENV.fetch("FRONTEND_URL", "http://localhost:5173")
        end
      end
    end
  end
end
