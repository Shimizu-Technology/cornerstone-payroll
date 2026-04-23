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
        # Admins see ALL staff users across all companies (staff is global, not per-client).
        def index
          users = User.includes(company_assignments: :company).order(:name)
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
          permitted = create_params
          company_ids_provided = permitted.key?(:company_ids)
          company_ids = permitted.delete(:company_ids)
          user = User.new(permitted)
          user.company_id = current_user.company_id
          user.clerk_id = "pending_#{SecureRandom.uuid}"
          user.invitation_status = "pending"
          user.invited_by = current_user
          user.invited_at = Time.current
          user.name = user.email.split("@").first.titleize if user.name.blank?

          ActiveRecord::Base.transaction do
            unless user.save
              return render json: { error: user.errors.full_messages }, status: :unprocessable_entity
            end

            sync_company_assignments!(user, company_ids: company_ids, role: user.role, company_ids_provided: company_ids_provided)
          end

          clerk_result = create_clerk_invitation(user)
          email_queued = false

          if clerk_result[:success] && clerk_result[:url].present?
            send_invite_email(user, clerk_result[:url])
            email_queued = true
          end

          render json: {
            data: user_json(user.reload),
            invitation_sent: email_queued,
            invitation_error: clerk_result[:success] ? nil : clerk_result[:error]
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/users/:id
        def update
          permitted = user_params
          requested_role = permitted[:role].presence || @user.role
          company_ids_provided = permitted.key?(:company_ids)
          company_ids = permitted.delete(:company_ids)

          if @user.id == current_user_id && permitted.key?(:role) && requested_role != @user.role
            return render json: { error: "Cannot change your own role" }, status: :unprocessable_entity
          end

          if @user.role == "admin" && permitted.key?(:role) && requested_role != "admin"
            if User.where(role: "admin", active: true).where.not(id: @user.id).none?
              return render json: { error: "Cannot demote the last active admin" }, status: :unprocessable_entity
            end
          end

          ActiveRecord::Base.transaction do
            @user.update!(permitted)
            sync_company_assignments!(@user, company_ids: company_ids, role: @user.role, company_ids_provided: company_ids_provided)
          end

          render json: { data: user_json(@user.reload) }
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
            if User.where(role: "admin", active: true).where.not(id: @user.id).none?
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
            if User.where(role: "admin", active: true).where.not(id: @user.id).none?
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

        def set_user
          @user = User.includes(company_assignments: :company).find_by(id: params[:id])
          return if @user

          render json: { error: "User not found" }, status: :not_found
        end

        def create_params
          params.require(:user).permit(:email, :name, :role, company_ids: [])
        end

        def user_params
          params.require(:user).permit(:email, :name, :role, :active, company_ids: [])
        end

        def sync_company_assignments!(user, company_ids:, role:, company_ids_provided:)
          unless role_requires_client_assignment?(role)
            user.company_assignments.destroy_all if user.company_assignments.exists?
            return
          end

          return unless company_ids_provided

          normalized_company_ids = normalize_company_ids(company_ids)

          if user.company_id != current_user.company_id
            return if normalized_company_ids.sort == current_assignment_ids_for(user).sort

            user.errors.add(:base, "Client assignments can only be edited for users in your staff workspace")
            raise ActiveRecord::RecordInvalid, user
          end

          unauthorized_ids = normalized_company_ids - assignable_company_ids
          if unauthorized_ids.any?
            user.errors.add(:base, "One or more companies are not accessible")
            raise ActiveRecord::RecordInvalid, user
          end

          user.company_assignments.destroy_all
          normalized_company_ids.each do |company_id|
            user.company_assignments.create!(company_id: company_id)
          end
        end

        def normalize_company_ids(raw_ids)
          Array(raw_ids).filter_map do |value|
            next if value.blank?

            value.to_i
          end.uniq
        end

        def current_assignment_ids_for(user)
          if user.association(:company_assignments).loaded?
            user.company_assignments.map(&:company_id)
          else
            user.company_assignments.pluck(:company_id)
          end
        end

        def assignable_company_ids
          @assignable_company_ids ||= current_user.accessible_company_ids
        end

        def role_requires_client_assignment?(role)
          role == "manager" || role == "accountant"
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

          assigned_companies = if user.association(:company_assignments).loaded?
            user.company_assignments.filter_map(&:company)
          else
            Company.where(id: assigned)
          end
          if assigned_companies.any?
            data[:assigned_companies] = assigned_companies.map do |company|
              {
                id: company.id,
                name: company.name
              }
            end
          end

          data
        end
      end
    end
  end
end
