# frozen_string_literal: true

module Api
  module V1
    module Admin
      class RecordActivitiesController < BaseController
        # Company history remains readable while a copy is preparing or needs repair.
        skip_before_action :enforce_test_workspace_safety!, if: -> { params[:record_type] == "companies" }

        DEFAULT_PER_PAGE = 25
        MAX_PER_PAGE = 100
        LIMITED_TECHNICAL_FIELDS = %i[actor_email ip_address request_id user_agent].freeze

        def index
          query = RecordActivityQuery.new(
            record_type: params[:record_type],
            record_id: params[:record_id],
            company_id: current_company_id
          )
          scope = query.call
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
          total = scope.count
          logs = scope
                       .newest_first
                       .includes(:user, :company, :organization)
                       .offset((page - 1) * per_page)
                       .limit(per_page)
                       .to_a
          pay_period_subjects = AuditLogPresenter.preload_pay_period_subjects(logs)

          render json: {
            creator: RecordCreator.call(query.record),
            data: logs.map { |log| record_activity_json(log, pay_period_subjects) },
            meta: {
              current_page: page,
              per_page: per_page,
              total_count: total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        rescue RecordActivityQuery::RecordNotFoundError
          render json: { error: "Record not found" }, status: :not_found
        end

        private

        def record_activity_json(log, pay_period_subjects)
          payload = AuditLogSerializer.call(log, pay_period_subjects: pay_period_subjects)
          return payload if StaffRolePolicy.allowed?(current_user, :view_audit_history)

          metadata = payload.fetch(:metadata, {}) || {}
          payload.except(*LIMITED_TECHNICAL_FIELDS).merge(
            metadata: metadata.except("http_method", "path", :http_method, :path)
          )
        end
      end
    end
  end
end
