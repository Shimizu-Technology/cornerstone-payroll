# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeNotesController < BaseController
        INDEX_LIMIT = 200

        before_action :skip_default_audit_log!
        before_action :set_employee
        before_action :set_note, only: %i[hide original]

        # GET /api/v1/admin/employees/:employee_id/notes
        def index
          scope = @employee.employee_notes.where(company_id: current_company_id)
          notes = scope
            .includes(:created_by, :hidden_by)
            .newest_first
            .limit(INDEX_LIMIT)
            .to_a
          total_count = scope.count

          render json: {
            data: notes.map { |note| serialize_note(note) },
            meta: {
              limit: INDEX_LIMIT,
              returned_count: notes.length,
              total_count: total_count,
              truncated: total_count > notes.length
            }
          }
        end

        # POST /api/v1/admin/employees/:employee_id/notes
        def create
          note = nil

          EmployeeNote.transaction do
            current_company.lock!
            revalidate_current_company_write_access!
            note = @employee.employee_notes.create!(
              company: current_company,
              created_by: current_user,
              body: create_body_param
            )
            AuditLog.record!(
              user: current_user,
              company_id: current_company_id,
              action: "employee_notes#create",
              record_type: "employee_notes",
              record_id: note.id,
              subject_name: @employee.full_name,
              metadata: {
                employee_id: @employee.id,
                note_id: note.id,
                body_length: note.body.length
              },
              ip_address: request.remote_ip,
              user_agent: request.user_agent,
              request_id: request.request_id
            )
          end

          render json: { data: serialize_note(note) }, status: :created
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :bad_request
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
        end

        # PATCH /api/v1/admin/employees/:employee_id/notes/:id/hide
        def hide
          EmployeeNote.transaction do
            current_company.lock!
            revalidate_current_company_write_access!
            @note.lock!
            @note.hide!(actor: current_user, reason: hide_reason_param)
            AuditLog.record!(
              user: current_user,
              company_id: current_company_id,
              action: "employee_notes#hide",
              record_type: "employee_notes",
              record_id: @note.id,
              subject_name: @employee.full_name,
              metadata: {
                employee_id: @employee.id,
                note_id: @note.id,
                body_length: @note.body.length,
                hidden_reason_length: @note.hidden_reason.length
              },
              ip_address: request.remote_ip,
              user_agent: request.user_agent,
              request_id: request.request_id
            )
          end

          render json: { data: serialize_note(@note) }
        rescue ActionController::ParameterMissing => e
          render json: { error: e.message }, status: :bad_request
        rescue ActiveRecord::RecordInvalid => e
          render json: {
            error: "Validation failed",
            details: e.record.errors.messages
          }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/employees/:employee_id/notes/:id/original
        def original
          unless @note.hidden?
            return render json: { error: "Note is not hidden" }, status: :unprocessable_entity
          end

          AuditLog.record!(
            user: current_user,
            company_id: current_company_id,
            action: "employee_notes#reveal",
            record_type: "employee_notes",
            record_id: @note.id,
            subject_name: @employee.full_name,
            metadata: {
              employee_id: @employee.id,
              note_id: @note.id
            },
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            request_id: request.request_id
          )

          render json: { data: serialize_note(@note, include_hidden_body: true) }
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          return if @employee

          render json: { error: "Employee not found" }, status: :not_found
        end

        def set_note
          @note = @employee.employee_notes.find_by(id: params[:id], company_id: current_company_id)
          return if @note

          render json: { error: "Note not found" }, status: :not_found
        end

        def create_body_param
          params.require(:note).permit(:body)[:body]
        end

        def hide_reason_param
          permitted = params.require(:note).permit(:reason, :hidden_reason)
          permitted[:reason].presence || permitted[:hidden_reason]
        end

        def serialize_note(note, include_hidden_body: false)
          {
            id: note.id,
            company_id: note.company_id,
            employee_id: note.employee_id,
            body: (note.hidden? && !include_hidden_body) ? nil : note.body,
            created_by_id: note.created_by_id,
            created_by_name: note.created_by&.name.presence || "Staff",
            created_at: note.created_at&.iso8601,
            hidden: note.hidden?,
            hidden_at: note.hidden_at&.iso8601,
            hidden_by_id: note.hidden_by_id,
            hidden_by_name: note.hidden_by&.name.presence,
            hidden_reason: note.hidden_reason
          }
        end
      end
    end
  end
end
