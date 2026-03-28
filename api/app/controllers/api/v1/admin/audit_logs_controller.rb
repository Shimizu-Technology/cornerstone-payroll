# frozen_string_literal: true

module Api
  module V1
    module Admin
      class AuditLogsController < BaseController
        before_action :require_admin!

        # GET /api/v1/admin/audit_logs
        # Super admins see audit logs across all companies they can access.
        # Optionally filter by company_id param to scope to active client.
        def index
          logs = if current_user.super_admin?
            if params[:company_id].present?
              AuditLog.where(company_id: params[:company_id])
            else
              AuditLog.all
            end
          else
            AuditLog.where(company_id: current_user.accessible_company_ids)
          end

          logs = logs.order(created_at: :desc)

          logs = logs.where(user_id: params[:user_id]) if params[:user_id].present?
          logs = logs.where("action ILIKE ?", "%#{params[:action_filter]}%") if params[:action_filter].present?
          logs = logs.where("record_type ILIKE ?", "%#{params[:record_type]}%") if params[:record_type].present?
          logs = logs.where(record_id: params[:record_id]) if params[:record_id].present?

          begin
            logs = logs.where("created_at >= ?", Time.zone.parse(params[:from])) if params[:from].present?
            logs = logs.where("created_at <= ?", Time.zone.parse(params[:to])) if params[:to].present?
          rescue ArgumentError
            return render json: { error: "Invalid date format" }, status: :unprocessable_entity
          end

          logs = logs.limit((params[:limit] || 200).to_i)

          render json: {
            data: logs.includes(:user).map { |log| audit_log_json(log) }
          }
        end

        private

        def audit_log_json(log)
          {
            id: log.id,
            action: log.action,
            record_type: log.record_type,
            record_id: log.record_id,
            user_id: log.user_id,
            user_name: log.user&.name,
            company_id: log.company_id,
            metadata: log.metadata,
            ip_address: log.ip_address,
            user_agent: log.user_agent,
            created_at: log.created_at
          }
        end
      end
    end
  end
end
