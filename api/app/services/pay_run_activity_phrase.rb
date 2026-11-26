# frozen_string_literal: true

# Plain-language wording for the actions taken inside a pay run: what was
# done, to whom, and the amounts or revisions involved. Returns the phrase
# that follows the actor's name, or nil when the generic wording applies.
# Only names, amounts, counts and check numbers are used; never tax IDs or
# bank details.
class PayRunActivityPhrase
  include ActiveSupport::NumberHelper

  PREVIEW_PARTS = { "checks" => "checks", "stubs" => "pay stubs" }.freeze
  SOURCE_FILES = { "revel_hours" => "Revel PDF", "supplemental_workbook" => "workbook" }.freeze
  HOUR_FIELDS = {
    "hours_worked" => "regular", "overtime_hours" => "overtime", "holiday_hours" => "holiday", "pto_hours" => "PTO"
  }.freeze
  PAYMENT_METHODS = { "direct_deposit" => "direct deposit", "paper_check" => "paper check" }.freeze
  ITEM_CHECK_ACTIONS = {
    "checks#mark_printed" => "marked the check printed for",
    "checks#mark_delivered" => "marked the check delivered for",
    "checks#confirm_direct_deposit_payment" => "confirmed the direct deposit for",
    "checks#void" => "voided the check for",
    "checks#reprint" => "reprinted the check for",
    "checks#replace_check" => "replaced the check for",
    "checks#reverse_paycheck" => "reversed the paycheck for",
    "payroll_item#reversed" => "reversed the paycheck for",
    "payroll_item#fit_override" => "changed final Guam income tax withholding for"
  }.freeze
  FIXED = {
    "reopen_unpaid" => "reopened unpaid payroll",
    "checks#mark_all_printed" => "marked all checks printed",
    "checks#batch_pdf" => "downloaded all checks as one PDF",
    "payroll_imports#rematch" => "matched the import files again",
    "timecard_imports#preview" => "uploaded timecards for review",
    "timecard_imports#apply" => "applied timecard hours",
    "time_tracking_imports#preview" => "reviewed time-tracking hours",
    "time_tracking_imports#apply" => "applied time-tracking hours"
  }.freeze

  INPUT_LABELS = {
    "salary_override" => "pay", "hours_worked" => "regular hours", "overtime_hours" => "overtime hours",
    "holiday_hours" => "holiday hours", "pto_hours" => "PTO hours", "bonus" => "bonus", "reported_tips" => "reported tips",
    "tips_paid_out" => "tips paid out", "non_taxable_pay" => "non-taxable pay", "service_charge_wages" => "service charge",
    "loan_payment" => "loan payment", "loan_deduction" => "loan deduction", "additional_withholding" => "extra withholding"
  }.freeze
  # Saving a row re-reads the employee's rate and type; they are not entries.
  ROW_CONTEXT_FIELDS = %w[pay_rate employment_type wage_rate_hours].freeze
  PHRASED_ACTIONS = %w[
    pay_periods#run_payroll
    checks#preview_pdf client_payroll_review#preview_pdf
    payroll_entry_resolutions#save payroll_entry_resolutions#destroy pay_period_excluded_employees#destroy
    payroll_items#create payroll_items#update payroll_items#destroy payroll_items#recalculate
    payroll_item#payment_delivery_method_changed
    payroll_imports#preview payroll_imports#remove_source payroll_imports#tip_treatment payroll_imports#apply
    employee_loans#create employee_loans#reactivate
    check_print_generations#create check_print_runs#generated check_print_runs#pdf
    checks#check_number_updated checks#update_check_number
    payroll_review#published payroll_review#withdrawn payroll_review#changes_requested payroll_review#approved payroll_review#overridden
    client_pay_stubs#download
  ].freeze

  # A worker opening their own pay stub in the AIRE app has no staff actor.
  WORKER_STATEMENT_HEADLINES = {
    "worker_statement#viewed" => "viewed their pay stub in",
    "worker_statement#pdf_downloaded" => "downloaded their pay stub PDF from"
  }.freeze

  def self.worker_headline(log)
    phrase = WORKER_STATEMENT_HEADLINES[log.action]
    return unless phrase

    source_name = log.metadata&.fetch("source_name", nil).presence || "the AIRE app"
    "#{log.subject_name.presence || 'A worker'} #{phrase} #{source_name}"
  end

  def self.handles?(action)
    FIXED.key?(action) || ITEM_CHECK_ACTIONS.key?(action) || PHRASED_ACTIONS.include?(action)
  end

  def self.call(log, run_label:, lookup_employee_name: nil)
    new(log, run_label: run_label, lookup_employee_name: lookup_employee_name).call
  end

  # One line per employee whose hours or amounts a calculation changed.
  def self.detail_lines(log)
    return [] unless log.action == "pay_periods#run_payroll"

    new(log, run_label: nil).input_change_lines
  end

  def initialize(log, run_label:, lookup_employee_name: nil)
    @log = log
    @metadata = log.metadata || {}
    @run_label = run_label
    @lookup_employee_name = lookup_employee_name
  end

  def call
    return FIXED[log.action] if FIXED.key?(log.action)
    return "#{ITEM_CHECK_ACTIONS[log.action]} #{name}" if ITEM_CHECK_ACTIONS.key?(log.action) && name

    case log.action
    when "pay_periods#run_payroll" then calculation_with_inputs
    when "checks#preview_pdf", "client_payroll_review#preview_pdf" then preview_download
    when "payroll_entry_resolutions#save" then resolution_saved
    when "payroll_entry_resolutions#destroy" then resolution_undone
    when "pay_period_excluded_employees#destroy" then "added #{name || 'an employee'} back to #{run_label}"
    when "payroll_items#destroy" then "removed #{name || 'an employee'} from #{run_label}"
    when "payroll_items#create" then item_created
    when "payroll_items#update" then item_updated
    when "payroll_items#recalculate" then "recalculated pay for #{name || 'an employee'}"
    when "payroll_item#payment_delivery_method_changed" then payment_method_changed
    when "payroll_imports#preview" then "uploaded files for import review#{files_suffix}"
    when "payroll_imports#remove_source" then "removed the #{SOURCE_FILES.fetch(metadata['source_role'].to_s, 'file')} from the import"
    when "payroll_imports#tip_treatment" then tip_treatment
    when "payroll_imports#apply" then import_applied
    when "employee_loans#create" then loan_created
    when "employee_loans#reactivate" then "reactivated the loan for #{name || 'an employee'}"
    when "check_print_generations#create" then "requested a check package: #{pluralize(metadata['selected_count'], 'check')}"
    when "check_print_runs#generated" then package_generated
    when "check_print_runs#pdf" then saved_pdf_opened
    when "checks#check_number_updated", "checks#update_check_number" then check_number_changed
    when "payroll_review#published" then "sent #{revision_label} to the client for approval"
    when "payroll_review#withdrawn" then "withdrew #{revision_label} from client review"
    when "payroll_review#changes_requested" then "asked for changes to #{revision_label}"
    when "payroll_review#overridden" then "approved #{revision_label} for the client (Cornerstone override)"
    when "payroll_review#approved" then "recorded client approval of #{revision_label}"
    when "client_pay_stubs#download" then "downloaded the pay stub for #{name || 'an employee'} from the client portal"
    end
  end

  def input_change_lines
    Array(metadata["input_changes"]).map do |change|
      before = change["before_values"] || {}
      changes = (change["after_values"] || {}).map do |field, value|
        "#{INPUT_LABELS.fetch(field, field.tr('_', ' '))} #{input_value(field, before[field])} → #{input_value(field, value)}"
      end
      "#{change['employee_name'] || 'An employee'}: #{changes.join(', ')}"
    end
  end

  private

  attr_reader :log, :metadata, :run_label

  def calculation_with_inputs
    changes = Array(metadata["input_changes"])
    return if changes.empty?

    count = metadata["input_change_count"].to_i
    return "calculated payroll with changed entries for #{pluralize(count, 'employee')}" if count > 1

    change = changes.first
    entered = entered_summary(change["after_values"] || {})
    "calculated payroll with new entries for #{change['employee_name'] || 'an employee'}#{": #{entered}" if entered}"
  end

  def input_value(field, value)
    # A pay amount entered for the first time had no earlier value; a real
    # zero still reads as 0 or $0.00.
    return "not set" if value.blank?

    field.end_with?("_hours") || field == "hours_worked" ? number(value) : money(value)
  end

  def name
    @name ||= log.subject_name.presence || metadata["employee_name"].presence || looked_up_name
  end

  def looked_up_name
    employee_id = metadata["employee_id"] || metadata.dig("resolution", "employee_id")
    @lookup_employee_name&.call(employee_id) if employee_id.present?
  end

  def preview_download
    revision = metadata["revision"].to_i
    part = PREVIEW_PARTS.fetch(metadata["part"].to_s, "checks and pay stubs")
    "downloaded the preview: #{part}#{" (revision #{revision})" if revision.positive?}"
  end

  def resolution_saved
    note = metadata.dig("resolution", "note").to_s.strip
    phrase = if field_resolution?
      "marked #{field_label} none this period for #{name || 'an employee'}"
    else
      "marked #{name || 'an employee'} Not paid this period"
    end
    note.present? ? "#{phrase}: “#{note.truncate(200)}”" : phrase
  end

  def resolution_undone
    return "undid none for #{field_label} for #{name || 'an employee'}" if field_resolution?

    "undid Not paid for #{name || 'an employee'}"
  end

  def field_resolution?
    metadata.dig("resolution", "payroll_standing_change_id").present?
  end

  def field_label
    return "“#{metadata['field_label']}”" if metadata["field_label"].present?

    metadata["field_kind"] == "extra_hours" ? "extra hours" : "pay"
  end

  def item_created
    after = metadata["after_values"] || {}
    # The import review creates the row only to hold the pay it asked for.
    return pay_saved(after) if metadata["source"] == "import_review" && after["salary_override"].present?

    entered = entered_summary(after)
    "added #{name || 'an employee'} to #{run_label}#{": #{entered}" if entered}"
  end

  def item_updated
    after = metadata["after_values"] || {}
    return pay_saved(after) if after["salary_override"].present?

    hours = hours_summary(after)
    return "saved hours for #{name || 'an employee'}: #{hours}" if hours && (after.keys - HOUR_FIELDS.keys - ROW_CONTEXT_FIELDS).empty?

    entered = entered_summary(after)
    "updated payroll for #{name || 'an employee'}#{": #{entered}" if entered}"
  end

  def pay_saved(values)
    "saved #{metadata['owner_pay'] ? 'owner pay' : 'pay'} for #{name || 'an employee'}: #{money(values['salary_override'])}"
  end

  def entered_summary(values)
    parts = []
    parts << "#{metadata['owner_pay'] ? 'owner pay' : 'pay'} #{money(values['salary_override'])}" if values["salary_override"].present?
    parts << hours_summary(values)
    {
      "bonus" => "bonus", "reported_tips" => "reported tips", "tips_paid_out" => "tips paid out",
      "non_taxable_pay" => "non-taxable pay", "service_charge_wages" => "service charge",
      "loan_payment" => "loan payment", "loan_deduction" => "loan deduction", "additional_withholding" => "extra withholding"
    }.each { |field, label| parts << "#{label} #{money(values[field])}" if values.key?(field) }
    parts << "check #{values['check_number']}" if values["check_number"].present?
    parts.compact.join(", ").presence
  end

  def hours_summary(values)
    parts = HOUR_FIELDS.filter_map do |field, label|
      "#{number(values[field])} #{label}" if values.key?(field)
    end
    parts.join(", ").presence
  end

  def payment_method_changed
    from = PAYMENT_METHODS.fetch(metadata["from"].to_s, metadata["from"].to_s.tr("_", " "))
    to = PAYMENT_METHODS.fetch(metadata["to"].to_s, metadata["to"].to_s.tr("_", " "))
    "changed the payment method for #{name || 'an employee'} from #{from} to #{to}"
  end

  def tip_treatment
    paid = metadata["tips_paid_out_from_tips"]
    return "recorded the import's tip choice" if paid.nil?

    "recorded that tips were #{paid ? 'already paid out' : 'not paid yet'}"
  end

  def import_applied
    count = metadata["applied_count"]
    summary = count.nil? ? "applied the import" : "applied the import: #{pluralize(count, 'employee')}"
    "#{summary}#{files_suffix}"
  end

  def files_suffix
    files = Array(metadata["source_files"]).filter_map { |role| SOURCE_FILES[role.to_s] }
    files.any? ? " (#{files.join(', ')})" : ""
  end

  def loan_created
    payment = metadata["payment_amount"]
    "set up a loan for #{name || 'an employee'}#{": #{money(payment)} per payroll" if payment.present?}"
  end

  def package_generated
    numbers = Array(metadata["check_numbers"])
    package = metadata["package_number"].present? ? "check package ##{metadata['package_number']}" : "a check package"
    count = metadata["selected_count"] || numbers.size
    range = CheckNumberRangeFormatter.format(numbers).gsub(/(\d)-(\d)/, "\\1–\\2")
    "generated #{package}: #{pluralize(count, 'check')}#{", #{range}" if range.present?}"
  end

  def saved_pdf_opened
    # The print dialog shows the saved file as soon as it opens.
    verb = metadata["access_type"] == "download" ? "downloaded" : "viewed"
    package = metadata["package_number"].present? ? " for package ##{metadata['package_number']}" : ""
    "#{verb} the saved check PDF#{package}"
  end

  def check_number_changed
    before = metadata.dig("before_values", "check_number")
    after = metadata.dig("after_values", "check_number")
    target = name ? "for #{name} " : ""
    return "set the check number #{target}to #{after}" if before.blank?

    "changed the check number #{target}from #{before} to #{after}"
  end

  def revision_label
    revision = metadata["revision"].to_i
    revision.positive? ? "revision #{revision}" : "the payroll preview"
  end

  def pluralize(count, word)
    count = count.to_i
    "#{count} #{count == 1 ? word : word.pluralize}"
  end

  def money(value)
    number_to_currency(value.to_s.to_d)
  end

  def number(value)
    number_to_rounded(value.to_s.to_d, precision: 2, strip_insignificant_zeros: true)
  end
end
