# frozen_string_literal: true

class AuditLogPresenter
  REPORT_FORMAT_SUFFIXES = %w[pdf csv xlsx ascii].freeze
  REPORT_NAMES = {
    "payroll_register" => "payroll register",
    "payroll_summary_by_employee" => "payroll summary by employee",
    "deductions_contributions" => "deductions and contributions report",
    "paycheck_history" => "paycheck history",
    "retirement_plans" => "retirement plans report",
    "installment_loans" => "installment loans report",
    "tax_summary" => "tax summary",
    "ytd_summary" => "year-to-date summary",
    "annual_payroll_summary" => "annual payroll summary",
    "employee_pay_history" => "employee pay history",
    "form_941_gu" => "Form 941 preparation report",
    "quarterly_compliance_packet" => "quarterly compliance packet",
    "quarterly_compliance_packet_swica" => "SWICA wage record",
    "w2_gu" => "W-2GU report",
    "form_1099_nec" => "1099-NEC report",
    "full_print_package" => "full payroll print package",
    "transmittal_log" => "transmittal log"
  }.freeze
  VERBS = {
    "authentication#signed_in" => "signed in",
    "employees#create" => "added",
    "employees#update" => "updated",
    "employees#destroy" => "terminated",
    "employees#reactivate" => "reactivated",
    "client_employees#create" => "added",
    "client_employees#update" => "updated",
    "users#created" => "created the user account for",
    "users#updated" => "updated the user account for",
    "users#activated" => "activated the user account for",
    "users#deactivated" => "deactivated the user account for",
    "users#deleted" => "deleted the user account for",
    "users#invitation_resent" => "resent an invitation to",
    "users#create" => "created the user account for",
    "users#update" => "updated the user account for",
    "users#deactivate" => "deactivated the user account for",
    "users#destroy" => "deleted the user account for",
    "company_assignments#bulk_update" => "updated client access for",
    "pay_periods#create" => "created the pay period",
    "pay_periods#run_payroll" => "calculated payroll for",
    "pay_periods#approve" => "approved payroll for",
    "pay_periods#unapprove" => "reopened payroll approval for",
    "pay_periods#commit" => "processed payroll for",
    "pay_periods#destroy" => "deleted the pay period",
    "pay_periods#update" => "updated the pay period",
    "pay_periods#generate_fit_check" => "generated the FIT check for",
    "pay_periods#void" => "voided payroll for",
    "pay_periods#correct_pay_date" => "corrected the pay date for",
    "checks#update_check_number" => "updated the check number for",
    "checks#check_number_updated" => "updated the check number for",
    "non_employee_checks#update" => "updated",
    "non_employee_checks#updated" => "updated",
    "check_print_runs#generated" => "generated a check print package for",
    "check_print_runs#confirmed" => "confirmed printed checks for",
    "correct_committed_pay_date" => "corrected the committed pay date for",
    "create_correction_run" => "created a correction run for",
    "void_pay_period" => "voided payroll for"
  }.freeze

  def initialize(log)
    @log = log
  end

  def headline
    @headline ||= if log.action == "authentication#signed_in"
      "#{actor_name} signed in"
    elsif report_action?
      report_headline
    else
      [ actor_name, verb, subject ].compact_blank.join(" ")
    end
  end

  def summary
    context = log.company&.name.presence || log.organization&.name.presence
    @summary ||= context.blank? ? headline : "#{headline} · #{context}"
  end

  def subject
    @subject ||= report_action? ? report_subject : record_subject
  end

  private

  attr_reader :log

  def actor_name
    log.actor_name.presence || log.user&.name.presence || "System"
  end

  def verb
    VERBS[log.action] || fallback_verb
  end

  def fallback_verb
    action = log.action.to_s.split("#").last.to_s.tr("_", " ")
    action.presence || "performed an action on"
  end

  def fallback_subject
    type = log.record_type.to_s.sub(/^client_/, "").underscore.tr("_", " ").singularize
    return type if log.record_id.blank?

    "#{type} record"
  end

  def record_subject
    log.subject_name.presence || resolved_pay_period_subject || fallback_subject
  end

  def resolved_pay_period_subject
    return @resolved_pay_period_subject if defined?(@resolved_pay_period_subject)
    return unless pay_period_record?
    return if log.record_id.blank? || log.company_id.blank?

    pay_period = PayPeriod.select(:start_date, :end_date).find_by(id: log.record_id, company_id: log.company_id)
    @resolved_pay_period_subject = AuditRecordSnapshot.subject_name(pay_period)
  end

  def pay_period_record?
    %w[PayPeriod pay_period payperiod pay_periods].include?(log.record_type)
  end

  def report_action?
    return false unless log.event_category == "export"

    normalized_record_type = log.record_type.to_s.sub(/^client_/, "")
    normalized_record_type == "reports" || log.action.to_s.match?(%r{\A(?:client_)?reports#})
  end

  def report_headline
    [ actor_name, report_verb, report_subject_with_period ].compact_blank.join(" ")
  end

  def report_subject
    [ display_report_name, report_period_subject ].compact_blank.join(" · ")
  end

  def report_subject_with_period
    base = "the #{report_name}"
    return base if report_period_subject.blank?

    "#{base} for #{report_period_subject}"
  end

  def report_verb
    access_type = log.metadata&.fetch("access_type", nil).to_s
    return "downloaded" if access_type == "download"
    return "viewed a preview of" if access_type == "preview"
    return "opened" if access_type == "view"

    action_name = log.action.to_s.split("#").last.to_s
    return "viewed a preview of" if action_name.include?("preview")
    return "downloaded" if REPORT_FORMAT_SUFFIXES.any? { |suffix| action_name.end_with?("_#{suffix}") }
    return "opened" if action_name.include?("print")

    "accessed"
  end

  def report_name
    metadata_key = log.metadata&.fetch("report_key", nil).to_s
    return REPORT_NAMES.fetch(metadata_key, metadata_key.tr("_", " ")) if metadata_key.present?

    metadata_name = log.metadata&.fetch("report_name", nil).to_s
    return metadata_name.downcase if metadata_name.present?

    action_name = log.action.to_s.split("#").last.to_s
    normalized = REPORT_FORMAT_SUFFIXES.reduce(action_name) { |name, suffix| name.sub(/_#{suffix}\z/, "") }
    normalized = normalized.sub(/_preview\z/, "").sub(/_print\z/, "")
    REPORT_NAMES.fetch(normalized, normalized.tr("_", " ").presence || "report")
  end

  def display_report_name
    return report_name if report_name.match?(/[A-Z]/)

    report_name.titleize
  end

  def report_period_subject
    log.subject_name.presence || log.metadata&.fetch("report_period_subject", nil).presence || resolved_report_pay_period_subject
  end

  def resolved_report_pay_period_subject
    return @resolved_report_pay_period_subject if defined?(@resolved_report_pay_period_subject)

    pay_period_id = log.metadata&.fetch("pay_period_id", nil)
    return if pay_period_id.blank? || log.company_id.blank?

    pay_period = PayPeriod.select(:start_date, :end_date).find_by(id: pay_period_id, company_id: log.company_id)
    @resolved_report_pay_period_subject = AuditRecordSnapshot.subject_name(pay_period)
  end
end
