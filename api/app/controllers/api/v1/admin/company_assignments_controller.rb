# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CompanyAssignmentsController < BaseController
        include Auditable
        audit_actions :bulk_update
        before_action :require_admin!
        ASSIGNABLE_USER_ROLES = %w[manager accountant client].freeze

        # GET /api/v1/admin/company_assignments
        # List all assignments, optionally filtered by user_id
        def index
          assignments = scoped_assignments

          if params[:user_id].present?
            user = scoped_users.find_by(id: params[:user_id])
            return render json: { error: "User not found" }, status: :not_found unless user

            assignments = assignments.where(user_id: user.id)
          end

          render json: {
            data: assignments.map { |a| serialize_assignment(a) }
          }
        end

        # POST /api/v1/admin/company_assignments
        def create
          user = scoped_users.find_by(id: assignment_params[:user_id])
          return render json: { error: "User not found" }, status: :not_found unless user

          company_id = normalize_company_ids([ assignment_params[:company_id] ]).first
          unless assignable_company_ids.include?(company_id)
            return render json: { error: "Company not accessible" }, status: :forbidden
          end

          company = Company.find(company_id)
          assignment = CompanyAssignment.new(
            user: user,
            company: company,
            workspace_access_level: company.test_workspace? ? assignment_params[:workspace_access_level].presence || "operator" : nil,
            expires_at: company.test_workspace? ? assignment_params[:expires_at] : nil,
            granted_by: current_user
          )

          if assignment.save
            render json: { data: serialize_assignment(assignment) }, status: :created
          else
            render json: {
              error: "Validation failed",
              details: assignment.errors.messages
            }, status: :unprocessable_entity
          end
        end

        # PATCH /api/v1/admin/company_assignments/:id
        # The only API path that can grant or revoke client management.
        def update
          assignment = scoped_assignments.find_by(id: params[:id])
          return render json: { error: "Assignment not found" }, status: :not_found unless assignment
          return render json: { error: "Cannot change your own grant" }, status: :forbidden if assignment.user_id == current_user.id

          attributes = params.require(:company_assignment).permit(:client_management, :expires_at)
          unless [ true, false ].include?(attributes[:client_management])
            return render json: { error: "client_management must be a boolean" }, status: :unprocessable_entity
          end
          if attributes.key?(:expires_at) && !attributes[:expires_at].nil? && attributes[:expires_at] != ""
            begin
              attributes[:expires_at] = Time.iso8601(attributes[:expires_at].to_s)
            rescue ArgumentError
              return render json: { error: "expires_at must be an ISO 8601 timestamp" }, status: :unprocessable_entity
            end
          end
          CompanyAssignment.transaction do
            actor = User.lock.find(current_user.id)
            raise CompanyWriteAccessChanged unless actor.organization_admin? && actor.payroll_access_allowed? &&
              (actor.super_admin? || actor.organization_id == assignment.company.organization_id)
            assignment.lock!
            before_values = assignment.attributes.slice("client_management", "expires_at", "granted_by_id")
            assignment.assign_attributes(attributes)
            assignment.granted_by = actor
            assignment.save!(context: :client_management_update)
            AuditLog.record!(
              user: actor, company_id: assignment.company_id, organization_id: assignment.company.organization_id,
              action: "company_assignments#client_management_updated", record_type: "CompanyAssignment", record_id: assignment.id,
              metadata: { user_id: assignment.user_id, company_id: assignment.company_id, actor_id: actor.id,
                before_values: before_values, after_values: assignment.attributes.slice("client_management", "expires_at", "granted_by_id") },
              ip_address: request.remote_ip, request_id: request.request_id, event_category: "security"
            )
          end
          skip_default_audit_log!
          render json: { data: serialize_assignment(assignment) }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end

        # DELETE /api/v1/admin/company_assignments/:id
        def destroy
          assignment = scoped_assignments.find_by(id: params[:id])
          return render json: { error: "Assignment not found" }, status: :not_found unless assignment

          assignment.destroy!
          head :no_content
        end

        # PUT /api/v1/admin/company_assignments/bulk_update
        # Replaces all assignments for a given user
        def bulk_update
          user = scoped_users.find_by(id: params[:user_id])
          return render json: { error: "User not found" }, status: :not_found unless user

          company_ids = normalize_company_ids(params[:company_ids])
          unauthorized_ids = company_ids - assignable_company_ids
          if unauthorized_ids.any?
            return render json: { error: "One or more companies are not accessible" }, status: :forbidden
          end

          CompanyAssignment.transaction do
            existing_assignments = user.company_assignments.to_a
            retained_assignments = existing_assignments.select { |assignment| company_ids.include?(assignment.company_id) }
            retained_assignments.each do |assignment|
              assignment.user = user
              raise ActiveRecord::RecordInvalid, assignment unless assignment.valid?
            end
            # This endpoint replaces the full membership list, including
            # expired grants. Retained grants keep their original metadata.
            (existing_assignments - retained_assignments).each(&:destroy!)
            new_company_ids = company_ids - existing_assignments.map(&:company_id)
            new_company_ids.each do |cid|
              company = Company.find(cid)
              user.company_assignments.create!(
                company: company,
                workspace_access_level: company.test_workspace? ? "operator" : nil,
                granted_by: current_user
              )
            end
          end
          user.association(:company_assignments).reset

          render json: {
            data: user.company_assignments.includes(:company, :granted_by).map { |a| serialize_assignment(a) }
          }
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end

        private

        def scoped_users
          scope = User.where(role: ASSIGNABLE_USER_ROLES)
          return scope if current_user&.super_admin?

          scope.where(organization_id: current_user&.organization_id)
        end

        def scoped_assignments
          scope = CompanyAssignment.includes(:user, :company, :granted_by)
                                   .joins(:user)
                                   .where(users: { role: ASSIGNABLE_USER_ROLES })
                                   .where(company_id: assignable_company_ids)
          return scope if current_user&.super_admin?

          scope.where(users: { organization_id: current_user&.organization_id })
        end

        def assignable_company_ids
          @assignable_company_ids ||= current_user.accessible_company_ids
        end

        def normalize_company_ids(raw_ids)
          Array(raw_ids).filter_map do |value|
            next if value.blank?

            value.to_i
          end.uniq
        end

        def assignment_params
          params.require(:company_assignment).permit(:user_id, :company_id, :workspace_access_level, :expires_at)
        end

        def serialize_assignment(assignment)
          {
            id: assignment.id,
            user_id: assignment.user_id,
            user_name: assignment.user.name,
            user_email: assignment.user.email,
            company_id: assignment.company_id,
            company_name: assignment.company.name,
            test_workspace: assignment.company.test_workspace?,
            workspace_access_level: assignment.workspace_access_level,
            client_management: assignment.client_management,
            expires_at: assignment.expires_at,
            granted_by_id: assignment.granted_by_id,
            granted_by_name: assignment.granted_by&.name,
            created_at: assignment.created_at
          }
        end
      end
    end
  end
end
