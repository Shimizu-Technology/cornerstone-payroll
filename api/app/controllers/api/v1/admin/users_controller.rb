# frozen_string_literal: true

module Api
  module V1
    module Admin
      class UsersController < BaseController
        include Auditable
        audit_actions :activate, :deactivate, :resend_invitation, :destroy
        before_action :require_admin!
        before_action :set_user, only: [ :show, :update, :destroy, :activate, :deactivate, :resend_invitation ]

        # GET /api/v1/admin/users
        def index
          users = User.where(company_id: staff_company_id).includes(:company_assignments).order(:name)
          if params[:search].present?
            query = "%#{params[:search]}%"
            users = users.where("name ILIKE ? OR email ILIKE ?", query, query)
          end

          render json: { data: users.map { |user| user_json(user) } }
        end

        # GET /api/v1/admin/users/:id
        def show
          render json: { data: user_json(@user) }
        end

        # POST /api/v1/admin/users
        def create
          user = User.new(create_params)
          user.company_id = staff_company_id
          user.clerk_id = "pending_#{SecureRandom.uuid}"
          user.invitation_status = "pending"
          user.invited_by = current_user
          user.invited_at = Time.current
          user.name = user.email.split("@").first.titleize if user.name.blank?

          unless user.save
            return render json: { error: user.errors.full_messages }, status: :unprocessable_entity
          end

          clerk_result = create_clerk_invitation(user)
          email_queued = false

          if clerk_result[:success] && clerk_result[:url].present?
            send_invite_email(user, clerk_result[:url])
            email_queued = true
          end

          render json: {
            data: user_json(user),
            invitation_sent: email_queued,
            invitation_error: clerk_result[:success] ? nil : clerk_result[:error]
          }, status: :created
        end

        # PATCH /api/v1/admin/users/:id
        def update
          if @user.id == current_user_id && user_params.key?(:role) && user_params[:role].present? && user_params[:role] != @user.role
            return render json: { error: "Cannot change your own role" }, status: :unprocessable_entity
          end

          if @user.role == "admin" && user_params.key?(:role) && user_params[:role].present? && user_params[:role] != "admin"
            if User.where(company_id: staff_company_id, role: "admin", active: true).where.not(id: @user.id).none?
              return render json: { error: "Cannot demote the last active admin" }, status: :unprocessable_entity
            end
          end

          @user.update!(user_params)
          render json: { data: user_json(@user) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/users/:id/activate
        def activate
          @user.update!(active: true)
          render json: { data: user_json(@user) }
        end

        # POST /api/v1/admin/users/:id/deactivate
        def deactivate
          if @user.id == current_user_id
            return render json: { error: "Cannot deactivate your own account" }, status: :unprocessable_entity
          end

          if @user.role == "admin"
            if User.where(company_id: staff_company_id, role: "admin", active: true).where.not(id: @user.id).none?
              return render json: { error: "Cannot deactivate the last active admin" }, status: :unprocessable_entity
            end
          end

          @user.update!(active: false)
          render json: { data: user_json(@user) }
        end

        # DELETE /api/v1/admin/users/:id
        def destroy
          if @user.id == current_user_id
            return render json: { error: "Cannot delete your own account" }, status: :unprocessable_entity
          end

          if @user.role == "admin"
            if User.where(company_id: staff_company_id, role: "admin", active: true).where.not(id: @user.id).none?
              return render json: { error: "Cannot delete the last active admin" }, status: :unprocessable_entity
            end
          end

          if @user.clerk_invitation_id.present? && @user.invitation_pending?
            service = ClerkInvitationService.new
            service.revoke_invitation(@user.clerk_invitation_id) if service.configured?
          end

          @user.destroy!
          head :no_content
        end

        # POST /api/v1/admin/users/:id/resend_invitation
        def resend_invitation
          unless @user.invitation_pending?
            return render json: { error: "User has already accepted their invitation" }, status: :unprocessable_entity
          end

          if @user.clerk_invitation_id.present?
            service = ClerkInvitationService.new
            service.revoke_invitation(@user.clerk_invitation_id) if service.configured?
          end

          clerk_result = create_clerk_invitation(@user, ignore_existing: true)
          email_queued = false

          if clerk_result[:success] && clerk_result[:url].present?
            send_invite_email(@user, clerk_result[:url])
            email_queued = true
            @user.update!(invited_at: Time.current)
          end

          render json: {
            data: user_json(@user),
            invitation_sent: email_queued,
            invitation_error: clerk_result[:success] ? nil : clerk_result[:error]
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def staff_company_id
          current_user.super_admin? ? current_company_id : current_user.company_id
        end

        def set_user
          @user = User.includes(:company_assignments).find_by(id: params[:id], company_id: staff_company_id)
          return if @user

          render json: { error: "User not found" }, status: :not_found
        end

        def create_params
          params.require(:user).permit(:email, :name, :role)
        end

        def user_params
          params.require(:user).permit(:email, :name, :role, :active)
        end

        def create_clerk_invitation(user, ignore_existing: false)
          service = ClerkInvitationService.new
          unless service.configured?
            return { success: false, error: "Clerk API not configured" }
          end

          result = service.create_invitation(
            email: user.email,
            redirect_url: build_redirect_url,
            public_metadata: { role: user.role },
            ignore_existing: ignore_existing
          )

          if result[:success]
            begin
              user.update!(clerk_invitation_id: result[:invitation_id])
            rescue ActiveRecord::RecordInvalid => e
              service.revoke_invitation(result[:invitation_id]) if result[:invitation_id].present?
              return {
                success: false,
                error: "Invitation could not be saved locally: #{e.record.errors.full_messages.join(', ')}"
              }
            end
          end

          result
        end

        def send_invite_email(user, invitation_url)
          SendUserInviteEmailJob.perform_later(user.id, current_user&.id, invitation_url)
        end

        def build_redirect_url
          frontend = ENV.fetch("FRONTEND_URL") { ENV.fetch("ALLOWED_ORIGINS", "http://localhost:5173").split(",").first.strip }
          "#{frontend}/login"
        end

        def user_json(user)
          data = {
            id: user.id,
            email: user.email,
            name: user.name,
            role: user.role,
            company_id: user.company_id,
            active: user.active,
            super_admin: user.super_admin?,
            invitation_status: user.invitation_status,
            invitation_pending: user.invitation_pending?,
            invited_at: user.invited_at,
            last_login_at: user.last_login_at,
            created_at: user.created_at,
            updated_at: user.updated_at
          }

          assigned = if user.association(:company_assignments).loaded?
            user.company_assignments.map(&:company_id)
          else
            user.company_assignments.pluck(:company_id)
          end
          data[:assigned_company_ids] = assigned if assigned.any?

          data
        end
      end
    end
  end
end
