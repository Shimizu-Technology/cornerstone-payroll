# frozen_string_literal: true

require "csv"

module Api
  module V1
    module Admin
      class AuditLogsController < BaseController
        DEFAULT_PER_PAGE = 50
        MAX_PER_PAGE = 100

        before_action :validate_requested_company!

        def index
          scope = filtered_scope
          total = scope.count
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
          logs = ordered(scope).includes(:user, :company, :organization).offset((page - 1) * per_page).limit(per_page)

          render json: {
            data: logs.map { |log| audit_log_json(log) },
            meta: {
              current_page: page,
              per_page: per_page,
              total_count: total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        rescue ArgumentError
          render json: { error: "Invalid date format" }, status: :unprocessable_entity
        end

        def export
          scope = filtered_scope.reorder(nil)
          filename = "audit-history-#{Time.zone.today.iso8601}.csv"
          response.headers["Content-Type"] = "text/csv; charset=utf-8"
          response.headers["Content-Disposition"] = %(attachment; filename="#{filename}")
          self.response_body = audit_csv_stream(scope)
        rescue ArgumentError
          render json: { error: "Invalid date format" }, status: :unprocessable_entity
        end

        private

        def filtered_scope
          logs = accessible_scope
          if params[:company_id].present?
            company_id = params[:company_id].to_i
            logs = logs.where(company_id: company_id)
          end

          logs = logs.where(user_id: params[:user_id]) if params[:user_id].present?
          logs = logs.where("action ILIKE ?", "%#{AuditLog.sanitize_sql_like(params[:action_filter])}%") if params[:action_filter].present?
          logs = logs.where("record_type ILIKE ?", "%#{AuditLog.sanitize_sql_like(params[:record_type])}%") if params[:record_type].present?
          logs = logs.where(record_id: params[:record_id]) if params[:record_id].present?
          logs = logs.where("created_at >= ?", Time.zone.parse(params[:from])) if params[:from].present?
          logs = logs.where("created_at <= ?", Time.zone.parse(params[:to])) if params[:to].present?
          logs
        end

        def accessible_scope
          return AuditLog.all if current_user.super_admin?

          unless current_user.organization_admin?
            return AuditLog.where(company_id: scoped_company_id)
          end

          # Firm administrators retain their organization-wide governance
          # view even when a different client is active in the UI.
          company_ids = current_user.accessible_company_ids
          AuditLog.where(organization_id: current_user.organization_id)
                  .or(AuditLog.where(organization_id: nil, company_id: company_ids))
        end

        def validate_requested_company!
          return if params[:company_id].blank?

          requested_company_id = params[:company_id].to_i
          return if current_user.organization_admin? && current_user.accessible_company_ids.include?(requested_company_id)

          unless current_user.organization_admin?
            return if request.headers["X-Company-Id"].present? && requested_company_id == current_company_id
            return if request.headers["X-Company-Id"].blank? && current_user.accessible_company_ids.include?(requested_company_id)
          end

          render json: { error: "Not authorized" }, status: :forbidden
        end

        def scoped_company_id
          return current_company_id if params[:company_id].blank? || request.headers["X-Company-Id"].present?

          params[:company_id].to_i
        end

        def ordered(scope)
          scope.order(created_at: audit_order, id: audit_order)
        end

        def audit_order
          params[:sort_direction] == "asc" ? :asc : :desc
        end

        def csv_safe(value)
          return value unless value.is_a?(String)
          return value unless value.match?(/\A[=+\-@]/)

          "'#{value}"
        end

        # Return an iterable response body so even a complete, multi-year
        # audit export has bounded memory use. The created_at/id cursor keeps
        # ordering stable when multiple events share a timestamp.
        def audit_csv_stream(scope)
          Enumerator.new do |stream|
            stream << CSV.generate_line([ "Time", "Person", "Activity", "Actor email", "Role", "Category", "Affected record", "Technical action", "Record type", "Record ID", "Organization", "Client", "IP address", "Request ID", "Advanced details" ])
            cursor = nil

            loop do
              batch = export_batch(scope, cursor)
              break if batch.empty?

              batch.each do |log|
                presenter = AuditLogPresenter.new(log)
                stream << CSV.generate_line([
                  log.created_at&.iso8601,
                  log.actor_name.presence || log.user&.name || "System",
                  presenter.headline,
                  log.actor_email.presence || log.user&.email,
                  log.actor_role.presence || log.user&.role,
                  log.event_category,
                  presenter.subject,
                  log.action,
                  log.record_type,
                  log.record_id,
                  log.organization&.name,
                  log.company&.name,
                  log.ip_address,
                  log.request_id,
                  log.metadata.to_json
                ].map { |value| csv_safe(value) })
              end

              last = batch.last
              cursor = [ last.created_at, last.id ]
            end
          end
        end

        def export_batch(scope, cursor)
          relation = scope.includes(:user, :company, :organization)
          if cursor
            operator = audit_order == :asc ? ">" : "<"
            relation = relation.where(
              "audit_logs.created_at #{operator} :created_at OR (audit_logs.created_at = :created_at AND audit_logs.id #{operator} :id)",
              created_at: cursor.first,
              id: cursor.last
            )
          end

          ordered(relation).limit(1_000).to_a
        end

        def audit_log_json(log)
          presenter = AuditLogPresenter.new(log)
          {
            id: log.id,
            action: log.action,
            display_action: presenter.headline,
            display_subject: presenter.subject,
            summary: presenter.summary,
            event_category: log.event_category,
            record_type: log.record_type,
            record_id: log.record_id,
            subject_name: log.subject_name,
            user_id: log.user_id,
            user_name: log.actor_name.presence || log.user&.name,
            actor_email: log.actor_email.presence || log.user&.email,
            actor_role: log.actor_role.presence || log.user&.role,
            organization_id: log.organization_id,
            organization_name: log.organization&.name,
            company_id: log.company_id,
            company_name: log.company&.name,
            metadata: log.metadata,
            ip_address: log.ip_address,
            user_agent: log.user_agent,
            request_id: log.request_id,
            created_at: log.created_at
          }
        end
      end
    end
  end
end
