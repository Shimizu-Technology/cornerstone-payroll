# frozen_string_literal: true

module Api
  module V1
    module Admin
      class UsersController < BaseController
        include Auditable
        include InvitationDeliveryOutcome
        audit_actions :activate, :deactivate, :resend_invitation, :destroy
        before_action :require_admin!
        before_action :set_user, only: [ :show, :update, :destroy, :activate, :deactivate, :resend_invitation, :move_practice_copy, :lookup_clerk_id, :bind_clerk_id ]
        before_action :require_recovery_environment!, only: [ :lookup_clerk_id, :bind_clerk_id ]

        # GET /api/v1/admin/users
        # Organization admins see users in their firm; super admins can see all firms.
        def index
          users = manageable_users.includes(:organization, :invited_by, practice_company: :organization, company_assignments: :company, company: :organization).order(:name)
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

          if user.client? && company_ids_provided
            selected = Company.where(id: normalize_company_ids(company_ids))
            if selected.any?(&:test_workspace?)
              unless selected.one? && assignable_company_ids.include?(selected.first.id) && selected.first.sandbox?
                user.errors.add(:base, "Choose one practice copy for a separate practice-only login")
                raise ActiveRecord::RecordInvalid, user
              end
              user.practice_company = selected.first
              user.company = selected.first
            end
          end

          ActiveRecord::Base.transaction do
            user.save!
            sync_company_assignments!(user, company_ids: company_ids, role: user.role, company_ids_provided: company_ids_provided)
            user.association(:company_assignments).reset
            record_user_audit!("created", user, before_values: {}, after_values: user_audit_snapshot(user))
          end

          clerk_result = create_clerk_invitation(user)
          invitation_delivery = invitation_delivery_response(user, clerk_result)

          user = User.includes(:organization, :invited_by, company_assignments: :company).find(user.id)
          render json: {
            data: user_json(user),
            **invitation_delivery
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/users/:id
        def update
          return if reject_platform_owner_mutation!

          before_values = user_audit_snapshot(@user)
          permitted = user_params
          role_provided = params.dig(:user, :role).present?
          requested_role = role_provided ? requested_user_role : @user.role
          role_changing = requested_role != @user.role
          if role_changing && !role_manageable?(requested_role)
            return render json: { error: "Cannot assign that role" }, status: :forbidden
          end

          company_ids_provided = permitted.key?(:company_ids)
          company_ids = permitted.delete(:company_ids)

          if @user.id == current_user_id && role_changing
            return render json: { error: "Cannot change your own role" }, status: :unprocessable_entity
          end

          if @user.organization_admin? && role_provided && !organization_admin_role?(requested_role)
            if active_peer_admins(@user).none?
              return render json: { error: "Cannot demote the last active admin" }, status: :unprocessable_entity
            end
          end

          @user.with_lock do
            if @user.awaiting_clerk_binding? && @user.clerk_invitation_id.present? &&
              permitted.key?(:email) && permitted[:email] != @user.email
              @user.errors.add(:email, "cannot be changed while a Clerk invitation is on file")
              raise ActiveRecord::RecordInvalid, @user
            end

            @user.assign_attributes(permitted)
            @user.role = requested_role if role_changing
            sync_company_assignments!(@user, company_ids: company_ids, role: @user.role, company_ids_provided: company_ids_provided)
            @user.save!
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
          return if reject_closed_practice_copy!

          before_values = user_audit_snapshot(@user)
          ActiveRecord::Base.transaction do
            restore_practice_grant!(@user)
            @user.update!(active: true)
            record_user_audit!("activated", @user, before_values: before_values, after_values: user_audit_snapshot(@user))
          end
          render json: { data: user_json(@user) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/users/:id/deactivate
        def deactivate
          return if reject_platform_owner_mutation!

          if @user.id == current_user_id
            return render json: { error: "Cannot deactivate your own account" }, status: :unprocessable_entity
          end

          if @user.organization_admin?
            if active_peer_admins(@user).none?
              return render json: { error: "Cannot deactivate the last active admin" }, status: :unprocessable_entity
            end
          end

          ActiveRecord::Base.transaction do
            # Locked and re-read first, so a reactivation that committed in
            # between can't keep the login active: every field is written
            # from the current row. Recorded even when the login was already
            # closed (an employee login whose last link ended): an admin's
            # deactivation is never lifted by the employee's own rehire
            # reactivation (M4-2). Same login lock as EmployeeLinks.
            @user.lock!("FOR NO KEY UPDATE")
            before_values = user_audit_snapshot(@user)
            @user.update!(active: false, deactivated_at: ApplicationRecord.database_now, deactivation_reason: "deactivated")
            record_user_audit!("deactivated", @user, before_values: before_values, after_values: user_audit_snapshot(@user))
          end
          render json: { data: user_json(@user) }
        end

        # DELETE /api/v1/admin/users/:id
        def destroy
          return if reject_platform_owner_mutation!

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
        rescue ActiveRecord::RecordNotDestroyed, ActiveRecord::InvalidForeignKey
          next_step = if @user.practice_company_id?
            "Choose Deactivate instead, or choose Move to use the login with a current practice copy."
          else
            "Choose Deactivate instead; their history stays attached to their name."
          end
          render json: {
            error: "#{user_display_name(@user)} can't be deleted because their name is on payroll submissions, " \
                   "uploaded files, review history or other records that have to be kept. #{next_step}",
            code: "user_has_retained_history",
            practice_login: @user.practice_company_id?
          }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/users/:id/resend_invitation
        def resend_invitation
          return if reject_closed_practice_copy!

          restore_practice_grant!(@user)

          unless @user.invitation_pending?
            return render json: { error: "User has already accepted their invitation" }, status: :unprocessable_entity
          end
          # An employee app sign-up binds only through its link (EmployeeLinks).
          if @user.portal_employee?
            return render json: { error: "Employee app sign-ups are resent from the employee's record" }, status: :unprocessable_entity
          end

          before_values = user_audit_snapshot(@user)
          clerk_result = create_clerk_invitation(@user, ignore_existing: true)
          if clerk_result[:success] && clerk_result[:url].present?
            @user.update!(invited_at: Time.current)
          end
          invitation_delivery = invitation_delivery_response(@user, clerk_result)

          @user.reload
          record_user_audit_after_external_effect(
            "invitation_resent",
            @user,
            before_values: before_values,
            after_values: user_audit_snapshot(@user),
            extra_metadata: invitation_delivery
          )

          render json: {
            data: user_json(@user),
            **invitation_delivery
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        def lookup_clerk_id
          account = PayrollInvitation.new.recovery_account(@user, params[:clerk_id], actor: current_user)
          render json: { data: account.slice(:id, :name, :verified_emails) }
        rescue PayrollInvitation::BindingRefused => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def bind_clerk_id
          PayrollInvitation.new.recover!(@user, params[:clerk_id], confirm_email: params[:confirm_email],
            actor: current_user, request: request)
          skip_default_audit_log!
          render json: { data: user_json(@user) }
        rescue PayrollInvitation::BindingRefused => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/users/:id/move_practice_copy
        # Re-points a practice-only login whose copy has closed to another open
        # practice copy. Its history in the old copy stays attributed to it.
        def move_practice_copy
          target = Company.find_by(id: params[:company_id])
          activate = ActiveModel::Type::Boolean.new.cast(params[:activate]) == true
          service = TestWorkspace::MovePracticeLogin.new(user: @user, target_company: target, actor: current_user, activate: activate)
          service.call
          skip_default_audit_log!

          @user.reload
          invitation_delivery = {}
          if @user.invitation_pending?
            invitation_delivery = refresh_practice_invitation!(@user, activate: activate)
          end

          @user = User.includes(:organization, :invited_by, practice_company: :organization, company_assignments: :company).find(@user.id)
          render json: {
            data: user_json(@user),
            moved_from: { id: service.source_company.id, name: service.source_company.name },
            **invitation_delivery
          }
        rescue TestWorkspace::MovePracticeLogin::Refused => e
          status = e.code == :forbidden ? :forbidden : :unprocessable_entity
          render json: { error: e.message, code: e.code.to_s }, status: status
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def rls_system_reason
          "Organization user administration and audit"
        end

        # A practice login's copy closed (archived, expired, sealed). Activation
        # and invitations would fail model validation with an opaque message, so
        # say what happened and offer the move instead. An open copy whose grant
        # lapsed is not refused; restore_practice_grant! renews it.
        def reject_closed_practice_copy!
          return false unless @user.practice_company_id? && !@user.practice_portal_open?

          copy = @user.practice_company
          reason = TestWorkspace::MovePracticeLogin.closed_reason(copy)
          return false unless reason

          render json: {
            error: "#{user_display_name(@user)} belongs to practice copy #{copy&.name || 'that was removed'}, which is #{reason}. " \
                   "To use this login again, choose Move and pick a current practice copy.",
            code: "practice_copy_closed",
            practice_company_id: @user.practice_company_id
          }, status: :unprocessable_entity
          true
        end

        # A practice login may only ever hold a grant to its own copy. When that
        # copy is open but the grant lapsed or was removed, an administrator's
        # Activate or Resend renews it (expiring with the copy) instead of failing.
        def restore_practice_grant!(user)
          return unless user.practice_company_id? && TestWorkspace::MovePracticeLogin.open_copy?(user.practice_company)
          return if user.company_assignments.active_access.exists?(company_id: user.practice_company_id)

          user.company_assignments.where(company_id: user.practice_company_id).destroy_all
          user.company_assignments.create!(company: user.practice_company, granted_by: current_user)
          user.association(:company_assignments).reset
        end

        # Mirrors resend_invitation: a pending invitation is revoked and, when
        # the moved login is activated, replaced so it opens the new copy.
        # An inactive login keeps no live invitation.
        def refresh_practice_invitation!(user, activate:)
          unless activate
            TestWorkspace::PortalAccess.revoke_pending_invitation!(user)
            return {}
          end

          clerk_result = create_clerk_invitation(user, ignore_existing: true)
          user.update!(invited_at: Time.current) if clerk_result[:success] && clerk_result[:url].present?
          invitation_response = invitation_delivery_response(user, clerk_result)
          user.reload
          invitation_response
        rescue StandardError => e
          Rails.logger.error("[UsersController] Practice login moved but its invitation could not be refreshed for user #{user.id}: #{e.class}")
          invitation_status_response("failed", error: "The login was moved, but its invitation could not be sent. Use Resend.")
        end

        def user_display_name(user)
          user.name.presence || user.email
        end

        def reject_platform_owner_mutation!
          return false unless @user&.platform_owner?

          render json: { error: "The primary platform owner cannot be changed, deactivated, or deleted" }, status: :unprocessable_entity
          true
        end

        def set_user
          @user = manageable_users.includes(:organization, :invited_by, practice_company: :organization, company_assignments: :company).find_by(id: params[:id])
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
          if user.practice_company_id? && normalized_company_ids != [ user.practice_company_id ]
            user.errors.add(:base, "A practice-only login must stay assigned only to its practice copy")
            raise ActiveRecord::RecordInvalid, user
          end

          unauthorized_ids = normalized_company_ids - assignable_company_ids
          if unauthorized_ids.any?
            user.errors.add(:base, "One or more companies are not accessible")
            raise ActiveRecord::RecordInvalid, user
          end

          existing_assignments = user.company_assignments.to_a
          retained_assignments = existing_assignments.select do |assignment|
            normalized_company_ids.include?(assignment.company_id) ||
              # The Users payload lists active grants only. A name edit must
              # not erase hidden expired grants or renew their access.
              (assignment.expired? && (user.staff_member? || !assignment.company.test_workspace?))
          end
          retained_assignments.each do |assignment|
            # Retention must not bypass role/organization validation after a
            # role change (for example, staff becoming a client portal user).
            assignment.user = user
            raise ActiveRecord::RecordInvalid, assignment unless assignment.valid?
          end
          (existing_assignments - retained_assignments).each(&:destroy!)
          new_company_ids = normalized_company_ids - existing_assignments.map(&:company_id)
          new_company_ids.each do |company_id|
            company = Company.find(company_id)
            user.company_assignments.create!(
              company: company,
              workspace_access_level: company.test_workspace? ? "operator" : nil,
              granted_by: current_user
            )
          end
        end

        def current_assignment_ids_for(user)
          if user.association(:company_assignments).loaded?
            user.company_assignments.reject(&:expired?).map(&:company_id)
          else
            user.company_assignments.active_access.pluck(:company_id)
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

        def require_recovery_environment!
          return unless StagingOutboundPolicy.staging?

          render json: { error: "Use staging tester bindings to manage Clerk identities in staging" }, status: :forbidden
        end

        def role_manageable?(role)
          return false unless %w[super_admin org_admin admin manager accountant client].include?(role)

          role != "super_admin" || current_user.super_admin?
        end

        def role_requires_client_assignment?(role)
          role == "manager" || role == "accountant" || role == "client"
        end

        def create_clerk_invitation(user, ignore_existing: false)
          PayrollInvitation.new.send_invite(user, redirect_url: invitation_redirect_url, ignore_existing: ignore_existing)
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
            can_recover_clerk_invitation: !StagingOutboundPolicy.staging? && PayrollInvitation.recoverable_by?(user, current_user),
            invited_at: user.invited_at,
            invited_by_id: user.invited_by_id,
            invited_by_name: user.invited_by&.name,
            last_login_at: user.last_login_at,
            last_active_at: user.last_active_at,
            created_at: user.created_at,
            updated_at: user.updated_at,
            platform_owner: user.platform_owner?
          }

          if user.practice_company_id?
            copy = user.practice_company
            data[:practice_company_id] = user.practice_company_id
            data[:practice_company_name] = copy&.name
            data[:practice_company_source_id] = copy&.migration_source_company_id
            data[:practice_copy_closed_reason] = TestWorkspace::MovePracticeLogin.closed_reason(copy)
          end

          assigned = current_assignment_ids_for(user)
          data[:assigned_company_ids] = assigned if assigned.any?

          assigned_companies = if user.association(:company_assignments).loaded?
            user.company_assignments.reject(&:expired?).filter_map(&:company)
          else
            Company.where(id: assigned)
          end
          if assigned_companies.any?
            data[:assigned_companies] = assigned_companies.map do |company|
              {
                id: company.id,
                name: company.name,
                test_workspace: company.test_workspace?,
                workspace_access_level: user.company_assignments.find { |assignment| assignment.company_id == company.id }&.workspace_access_level
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
            "platform_owner" => user.platform_owner?,
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
          override_default_audit_action!("users#invitation_resent")
          Rails.logger.error(
            "[UsersController] Invitation completed but exact audit logging failed " \
            "for user #{target.id}: #{e.class}: #{e.message}"
          )
        end
      end
    end
  end
end
