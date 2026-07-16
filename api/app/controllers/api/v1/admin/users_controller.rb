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
        # Organization admins see users in their firm; super admins can see all firms.
        def index
          users = manageable_users.includes(:organization, :invited_by, company_assignments: :company, company: :organization).order(:name)
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
          requested_role = requested_user_role.presence
          unless role_manageable?(requested_role)
            return render json: { error: "Cannot assign that role" }, status: :forbidden
          end

          company_ids_provided = permitted.key?(:company_ids)
          company_ids = permitted.delete(:company_ids)
          user = User.new(permitted)
          user.role = requested_role
          user.company_id = current_user.company_id
          user.organization = current_user.organization
          user.clerk_id = "pending_#{SecureRandom.uuid}"
          user.invitation_status = "pending"
          user.invited_by = current_user
          user.invited_at = Time.current
          user.name = user.email.split("@").first.titleize if user.name.blank?

          ActiveRecord::Base.transaction do
            user.save!
            sync_company_assignments!(user, company_ids: company_ids, role: user.role, company_ids_provided: company_ids_provided)
            user.association(:company_assignments).reset
            record_user_audit!("created", user, before_values: {}, after_values: user_audit_snapshot(user))
          end

          clerk_result = create_clerk_invitation(user)
          email_queued = false

          if clerk_result[:success] && clerk_result[:url].present?
            send_invite_email(user, clerk_result[:url])
            email_queued = true
          end

          user = User.includes(:organization, :invited_by, company_assignments: :company).find(user.id)
          render json: {
            data: user_json(user),
            invitation_sent: email_queued,
            invitation_error: clerk_result[:success] ? nil : clerk_result[:error]
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/users/:id
        def update
          before_values = user_audit_snapshot(@user)
          permitted = user_params
          role_provided = params.dig(:user, :role).present?
          requested_role = role_provided ? requested_user_role : @user.role
          unless role_manageable?(requested_role)
            return render json: { error: "Cannot assign that role" }, status: :forbidden
          end

          company_ids_provided = permitted.key?(:company_ids)
          company_ids = permitted.delete(:company_ids)

          if @user.id == current_user_id && role_provided && requested_role != @user.role
            return render json: { error: "Cannot change your own role" }, status: :unprocessable_entity
          end

          if @user.organization_admin? && role_provided && !organization_admin_role?(requested_role)
            if active_peer_admins(@user).none?
              return render json: { error: "Cannot demote the last active admin" }, status: :unprocessable_entity
            end
          end

          ActiveRecord::Base.transaction do
            @user.assign_attributes(permitted)
            @user.role = requested_role if role_provided
            @user.save!
            sync_company_assignments!(@user, company_ids: company_ids, role: @user.role, company_ids_provided: company_ids_provided)
            @user.association(:company_assignments).reset
            record_user_audit!("updated", @user, before_values: before_values, after_values: user_audit_snapshot(@user))
          end

          @user = User.includes(:organization, :invited_by, company_assignments: :company).find(@user.id)
          render json: { data: user_json(@user) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/users/:id/activate
        def activate
          before_values = user_audit_snapshot(@user)
          ActiveRecord::Base.transaction do
            @user.update!(active: true)
            record_user_audit!("activated", @user, before_values: before_values, after_values: user_audit_snapshot(@user))
          end
          render json: { data: user_json(@user) }
        end

        # POST /api/v1/admin/users/:id/deactivate
        def deactivate
          if @user.id == current_user_id
            return render json: { error: "Cannot deactivate your own account" }, status: :unprocessable_entity
          end

          if @user.organization_admin?
            if active_peer_admins(@user).none?
              return render json: { error: "Cannot deactivate the last active admin" }, status: :unprocessable_entity
            end
          end

          before_values = user_audit_snapshot(@user)
          ActiveRecord::Base.transaction do
            @user.update!(active: false)
            record_user_audit!("deactivated", @user, before_values: before_values, after_values: user_audit_snapshot(@user))
          end
          render json: { data: user_json(@user) }
        end

        # DELETE /api/v1/admin/users/:id
        def destroy
          if @user.id == current_user_id
            return render json: { error: "Cannot delete your own account" }, status: :unprocessable_entity
          end

          if @user.organization_admin?
            if active_peer_admins(@user).none?
              return render json: { error: "Cannot delete the last active admin" }, status: :unprocessable_entity
            end
          end

          before_values = user_audit_snapshot(@user)
          if @user.clerk_invitation_id.present? && @user.invitation_pending?
            service = ClerkInvitationService.new
            service.revoke_invitation(@user.clerk_invitation_id) if service.configured?
          end

          ActiveRecord::Base.transaction do
            @user.destroy!
            record_user_audit!("deleted", @user, before_values: before_values, after_values: {})
          end
          head :no_content
        end

        # POST /api/v1/admin/users/:id/resend_invitation
        def resend_invitation
          unless @user.invitation_pending?
            return render json: { error: "User has already accepted their invitation" }, status: :unprocessable_entity
          end

          before_values = user_audit_snapshot(@user)
          if @user.clerk_invitation_id.present?
            service = ClerkInvitationService.new
            service.revoke_invitation(@user.clerk_invitation_id) if service.configured?
          end

          clerk_result = create_clerk_invitation(@user, ignore_existing: true)
          email_queued = false

          if clerk_result[:success] && clerk_result[:url].present?
            @user.update!(invited_at: Time.current)
            send_invite_email(@user, clerk_result[:url])
            email_queued = true
          end

          @user.reload
          record_user_audit_after_external_effect(
            "invitation_resent",
            @user,
            before_values: before_values,
            after_values: user_audit_snapshot(@user),
            extra_metadata: { invitation_sent: email_queued, invitation_error: clerk_result[:success] ? nil : clerk_result[:error] }
          )

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
          @user = manageable_users.includes(:organization, :invited_by, company_assignments: :company).find_by(id: params[:id])
          return if @user

          render json: { error: "User not found" }, status: :not_found
        end

        def create_params
          params.require(:user).permit(:email, :name, company_ids: [])
        end

        def user_params
          params.require(:user).permit(:email, :name, :active, company_ids: [])
        end

        def requested_user_role
          params.dig(:user, :role).to_s
        end

        def sync_company_assignments!(user, company_ids:, role:, company_ids_provided:)
          unless role_requires_client_assignment?(role)
            user.company_assignments.destroy_all if user.company_assignments.exists?
            return
          end

          return unless company_ids_provided

          normalized_company_ids = normalize_company_ids(company_ids)

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

        def current_assignment_ids_for(user)
          if user.association(:company_assignments).loaded?
            user.company_assignments.map(&:company_id)
          else
            user.company_assignments.pluck(:company_id)
          end
        end

        def normalize_company_ids(raw_ids)
          Array(raw_ids).filter_map do |value|
            next if value.blank?

            value.to_i
          end.uniq
        end

        def assignable_company_ids
          @assignable_company_ids ||= current_user.accessible_company_ids
        end

        def manageable_users
          return User.all if current_user&.super_admin?

          User.where(organization_id: current_user&.organization_id).where.not(role: User.roles.fetch("super_admin"))
        end

        def active_peer_admins(user)
          scope = User.active.where.not(id: user.id)
          if user.super_admin?
            scope.where(role: User.roles.fetch("super_admin"))
          else
            scope.where(organization_id: user.organization_id, role: organization_admin_roles)
          end
        end

        def organization_admin_roles
          User.roles.values_at("admin", "org_admin").compact
        end

        def organization_admin_role?(role)
          %w[admin org_admin].include?(role)
        end

        def role_manageable?(role)
          return false if role.blank?
          return true if current_user&.super_admin?

          role != "super_admin"
        end

        def role_requires_client_assignment?(role)
          role == "manager" || role == "accountant" || role == "client"
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
            organization_id: user.organization_id,
            organization_name: user.organization&.name,
            company_id: user.company_id,
            active: user.active,
            invitation_status: user.invitation_status,
            invitation_pending: user.invitation_pending?,
            invited_at: user.invited_at,
            invited_by_id: user.invited_by_id,
            invited_by_name: user.invited_by&.name,
            last_login_at: user.last_login_at,
            last_active_at: user.last_active_at,
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

        def user_audit_snapshot(user)
          {
            "id" => user.id,
            "name" => user.name,
            "email" => user.email,
            "role" => user.role,
            "active" => user.active,
            "invitation_status" => user.invitation_status,
            "invited_at" => user.invited_at&.iso8601,
            "assigned_company_ids" => current_assignment_ids_for(user).sort
          }
        end

        def record_user_audit!(verb, target, before_values:, after_values:, extra_metadata: {})
          changed_fields = (before_values.keys | after_values.keys).select do |field|
            before_values[field] != after_values[field]
          end

          AuditLog.record!(
            user: current_user,
            organization_id: target.organization_id,
            company_id: nil,
            action: "users##{verb}",
            record_type: "users",
            record_id: target.id,
            subject_name: target.name.presence || target.email,
            metadata: {
              before_values: before_values,
              after_values: after_values,
              changed_fields: changed_fields
            }.merge(extra_metadata).compact,
            event_category: "security"
          )
          skip_default_audit_log!
        end

        # A Clerk invitation and its email enqueue cannot participate in the
        # database transaction that stores an AuditLog. Once those external
        # effects succeed, an audit outage must not turn the response into a
        # 500 that encourages the operator to resend the invitation again.
        # Leave the generic Auditable after_action enabled as a best-effort
        # fallback when this exact lifecycle event cannot be persisted.
        def record_user_audit_after_external_effect(verb, target, before_values:, after_values:, extra_metadata: {})
          record_user_audit!(
            verb,
            target,
            before_values: before_values,
            after_values: after_values,
            extra_metadata: extra_metadata
          )
        rescue StandardError => e
          Rails.logger.error(
            "[UsersController] Invitation completed but exact audit logging failed " \
            "for user #{target.id}: #{e.class}: #{e.message}"
          )
        end
      end
    end
  end
end
