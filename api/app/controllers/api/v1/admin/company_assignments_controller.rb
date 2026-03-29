# frozen_string_literal: true

module Api
  module V1
    module Admin
      class CompanyAssignmentsController < BaseController
        include Auditable
        audit_actions :bulk_update
        before_action :require_admin!

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

          assignment = CompanyAssignment.new(user: user, company_id: company_id)

          if assignment.save
            render json: { data: serialize_assignment(assignment) }, status: :created
          else
            render json: {
              error: "Validation failed",
              details: assignment.errors.messages
            }, status: :unprocessable_entity
          end
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

          # Home company access already comes from the user's primary company_id.
          company_ids -= [ user.company_id ]

          CompanyAssignment.transaction do
            user.company_assignments.destroy_all
            company_ids.each do |cid|
              user.company_assignments.create!(company_id: cid)
            end
          end

          render json: {
            data: user.company_assignments.includes(:company).map { |a| serialize_assignment(a) }
          }
        end

        private

        def staff_company_id
          current_user.super_admin? ? current_company_id : current_user.company_id
        end

        def scoped_users
          User.where(company_id: staff_company_id)
        end

        def scoped_assignments
          CompanyAssignment.includes(:user, :company)
                           .joins(:user)
                           .where(users: { company_id: staff_company_id })
                           .where(company_id: assignable_company_ids)
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
          params.require(:company_assignment).permit(:user_id, :company_id)
        end

        def serialize_assignment(assignment)
          {
            id: assignment.id,
            user_id: assignment.user_id,
            user_name: assignment.user.name,
            user_email: assignment.user.email,
            company_id: assignment.company_id,
            company_name: assignment.company.name,
            created_at: assignment.created_at
          }
        end
      end
    end
  end
end
