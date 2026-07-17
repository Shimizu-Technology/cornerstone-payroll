# frozen_string_literal: true

# Auto-records AuditLog entries for successful mutating requests and sensitive
# document/export reads. It is included by the admin and client base
# controllers so coverage does not depend on every controller remembering to
# opt in.
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

  SAFE_METHODS = %w[GET HEAD OPTIONS].freeze
  SENSITIVE_READ_PATTERN = /(download|export|pdf|print|preview)/i
  FILTERED_PARAM_KEYS = %w[
    controller action format id authenticity_token password password_confirmation
    token access_token refresh_token secret shared_secret ssn ssn_encrypted
    routing_number account_number bank_account ciphertext file upload
  ].freeze

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
    return unless audit_worthy_request?
    return unless response.successful?
    return unless current_user
    return if @skip_default_audit_log
    return if Current.domain_audit_recorded

    record_type = controller_path.gsub("api/v1/admin/", "")
                                 .gsub("api/v1/client/", "client_")
                                 .gsub("api/v1/", "")
    action_label = "#{record_type}##{action_name}"

    record_id = params[:id]

    if action_name == "create" && record_id.blank?
      begin
        body = JSON.parse(response.body)
        record_id = extract_record_id_from_body(body)
      rescue JSON::ParserError
        # ignore
      end
    end

    response_subject = extract_response_subject
    record = audit_record_for_log
    record_id ||= response_subject&.fetch("id", nil)
    record_id ||= record&.id
    changes = AuditRecordSnapshot.changes_for(record)
    changed_fields = changes[:changed_fields].presence || safe_changed_fields

    AuditLog.record!(
      user: current_user,
      organization_id: current_user.organization_id,
      company_id: audit_company_id,
      action: action_label,
      record_type: record_type,
      record_id: record_id,
      subject_name: AuditRecordSnapshot.subject_name(record).presence || subject_name_from(response_subject),
      metadata: {
        http_method: request.request_method,
        path: request.path,
        changed_fields: changed_fields,
        before_values: changes[:before_values].presence,
        after_values: changes[:after_values].presence,
        redacted_fields: changes[:redacted_fields].presence,
        response_status: response.status
      }.compact,
      ip_address: request.remote_ip,
      user_agent: request.user_agent,
      request_id: request.request_id,
      event_category: audit_event_category
    )
  rescue => e
    Rails.logger.warn("[Auditable] Failed to write audit log: #{e.message}")
  end

  def audit_worthy_request?
    return true unless SAFE_METHODS.include?(request.request_method)
    return true if _extra_audit_actions.include?(action_name)

    action_name.match?(SENSITIVE_READ_PATTERN)
  end

  def audit_company_id
    return nil if organization_scoped_audit_controller?

    current_company_id
  end

  def organization_scoped_audit_controller?
    controller_path.match?(%r{api/v1/admin/(users|organizations|company_assignments|audit_logs|invoices|invoice_)})
  end

  def audit_event_category
    return "export" if action_name.match?(SENSITIVE_READ_PATTERN)
    return "security" if controller_path.match?(/users|organizations|company_assignments|invitations/)

    "activity"
  end

  def safe_changed_fields
    params.to_unsafe_h
          .reject { |key, _| FILTERED_PARAM_KEYS.include?(key.to_s) }
          .flat_map { |key, value| safe_field_names(key, value) }
          .uniq
          .sort
  end

  def audit_record_for_log
    return audit_record if respond_to?(:audit_record, true)

    nil
  end

  def safe_field_names(prefix, value)
    return [] if FILTERED_PARAM_KEYS.any? { |filtered| prefix.to_s.downcase.include?(filtered) }

    if value.is_a?(Hash)
      value.keys.filter_map do |key|
        next if FILTERED_PARAM_KEYS.any? { |filtered| key.to_s.downcase.include?(filtered) }

        "#{prefix}.#{key}"
      end
    else
      [ prefix.to_s ]
    end
  end

  def extract_response_subject
    body = JSON.parse(response.body)
    return body if body.is_a?(Hash) && body["id"].present?
    return body["data"] if body.is_a?(Hash) && body["data"].is_a?(Hash)

    body.values.find { |value| value.is_a?(Hash) && value["id"].present? } if body.is_a?(Hash)
  rescue JSON::ParserError, TypeError
    nil
  end

  def subject_name_from(subject)
    return nil unless subject

    subject["name"] || subject["title"] || subject["email"] || subject["employee_name"] || subject["payable_to"]
  end

  def extract_record_id_from_body(payload)
    return payload["id"] if payload.is_a?(Hash) && payload["id"].present?
    return payload.dig("data", "id") if payload.is_a?(Hash) && payload.dig("data", "id").present?

    if payload.is_a?(Hash)
      nested_hash = payload.values.find { |value| value.is_a?(Hash) && value["id"].present? }
      return nested_hash["id"] if nested_hash
    end

    nil
  end

  def skip_default_audit_log!
    @skip_default_audit_log = true
  end
end
