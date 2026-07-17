# frozen_string_literal: true

class AuditLogPresenter
  VERBS = {
    "authentication#signed_in" => "signed in",
    "employees#create" => "added",
    "employees#update" => "updated",
    "employees#destroy" => "terminated",
    "employees#reactivate" => "reactivated",
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
    "pay_periods#commit" => "committed payroll for",
    "pay_periods#destroy" => "deleted the pay period",
    "pay_periods#update" => "updated the pay period",
    "pay_periods#generate_fit_check" => "generated the FIT check for",
    "pay_periods#void" => "voided payroll for",
    "pay_periods#correct_pay_date" => "corrected the pay date for",
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
    return "#{actor_name} signed in" if log.action == "authentication#signed_in"

    [ actor_name, verb, subject ].compact_blank.join(" ")
  end

  def summary
    context = log.company&.name.presence || log.organization&.name.presence
    return headline if context.blank?

    "#{headline} · #{context}"
  end

  def subject
    log.subject_name.presence || fallback_subject
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
end
