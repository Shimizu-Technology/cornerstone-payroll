# frozen_string_literal: true

# Auto-records AuditLog entries for mutating actions.
#
# Include in any admin controller to get automatic audit logging:
#
#   class EmployeesController < BaseController
#     include Auditable
#   end
#
# By default, logs :create, :update, :destroy. To add custom actions:
#
#   class PayPeriodsController < BaseController
#     include Auditable
#     audit_actions :approve, :commit, :run_payroll, :void
#   end
#
module Auditable
  extend ActiveSupport::Concern

  DEFAULT_ACTIONS = [:create, :update, :destroy].freeze

  included do
    class_attribute :_extra_audit_actions, default: []
    after_action :write_audit_log
  end

  class_methods do
    def audit_actions(*actions)
      self._extra_audit_actions = actions.map(&:to_s)
    end
  end

  private

  def write_audit_log
    audited = DEFAULT_ACTIONS.map(&:to_s) + _extra_audit_actions
    return unless audited.include?(action_name)
    return unless response.successful?
    return unless current_user

    record_type = controller_path.gsub("api/v1/admin/", "")
    action_label = "#{record_type}##{action_name}"

    record_id = params[:id]

    if action_name == "create" && record_id.blank?
      begin
        body = JSON.parse(response.body)
        record_id = body.dig("data", "id")
      rescue JSON::ParserError
        # ignore
      end
    end

    metadata = {}
    %i[employee user pay_period company_assignment].each do |param_key|
      if params[param_key].present?
        metadata[:changed_fields] = params[param_key].keys
        break
      end
    end

    AuditLog.create(
      user: current_user,
      company_id: current_company_id,
      action: action_label,
      record_type: record_type,
      record_id: record_id,
      metadata: metadata,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  rescue => e
    Rails.logger.warn("[Auditable] Failed to write audit log: #{e.message}")
  end
end
