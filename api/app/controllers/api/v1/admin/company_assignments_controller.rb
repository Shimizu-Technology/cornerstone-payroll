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
          assignments = CompanyAssignment.includes(:user, :company)

          if params[:user_id].present?
            assignments = assignments.where(user_id: params[:user_id])
          end

          render json: {
            data: assignments.map { |a| serialize_assignment(a) }
          }
        end

        # POST /api/v1/admin/company_assignments
        def create
          assignment = CompanyAssignment.new(assignment_params)

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
          assignment = CompanyAssignment.find(params[:id])
          assignment.destroy!
          head :no_content
        end

        # PUT /api/v1/admin/company_assignments/bulk_update
        # Replaces all assignments for a given user
        def bulk_update
          user = User.find(params[:user_id])
          company_ids = Array(params[:company_ids]).map(&:to_i)

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
