# frozen_string_literal: true

class CheckNumberBatchCorrectionService
  class Error < StandardError; end

  SOURCE_TYPES = %w[payroll_item non_employee_check].freeze
  MAX_CHECK_NUMBER = 9_999_999

  def initialize(pay_period:, changes:, actor:, ip_address: nil, user_agent: nil, request_id: nil, reason: nil)
    @pay_period = pay_period
    @company = pay_period.company
    @changes = normalize_changes(changes)
    @actor = actor
    @ip_address = ip_address
    @user_agent = user_agent
    @request_id = request_id
    @reason = reason.to_s.strip.presence || "Saved from the check-number worksheet"
  end

  def call
    validate_request!
    return { updated_count: 0 } if changes.empty?

    updated_count = 0
    ApplicationRecord.transaction do
      company.lock!
      pay_period.lock!
      validate_pay_period!

      targets = load_and_lock_targets!
      effective_changes = changes.select do |change|
        targets.fetch(target_key(change)).check_number.to_s != change.fetch(:check_number).to_s
      end

      if effective_changes.any?
        validate_final_numbers!(effective_changes)
        snapshots = snapshot_targets(effective_changes, targets)

        # Clear every changed source before assigning final values. This allows a
        # reviewed worksheet to swap or resequence numbers without tripping the
        # per-table unique indexes halfway through an otherwise valid batch.
        snapshots.each_value do |snapshot|
          snapshot.fetch(:record).update_columns(check_number: nil, updated_at: Time.current)
        end

        effective_changes.each do |change|
          snapshot = snapshots.fetch(target_key(change))
          record = snapshot.fetch(:record)
          record.update!(check_number: change.fetch(:check_number))
          record_change!(record, snapshot.fetch(:old_number), change.fetch(:check_number), change.fetch(:source_type))
        end

        sync_documents!(snapshots)
        advance_company_sequence!(effective_changes)
      end

      updated_count = effective_changes.length
    end

    { updated_count: updated_count }
  rescue ActiveRecord::RecordNotUnique
    raise Error, "One or more check numbers are already in use for this company"
  end

  private

  attr_reader :pay_period, :company, :changes, :actor, :ip_address, :user_agent, :request_id, :reason

  def normalize_changes(raw_changes)
    Array(raw_changes).map do |raw|
      change = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw.to_h
      {
        source_type: change["source_type"].to_s,
        source_id: Integer(change["source_id"]),
        check_number: change["check_number"].to_s.strip.presence
      }
    rescue ArgumentError, TypeError
      raise Error, "Each check-number change must identify a valid check"
    end
  end

  def validate_request!
    raise Error, "User not found" unless actor
    raise Error, "No check-number changes were provided" unless changes.is_a?(Array)
    raise Error, "A maximum of 250 check numbers can be saved at once" if changes.length > 250

    duplicate_targets = changes.group_by { |change| target_key(change) }.select { |_key, rows| rows.length > 1 }
    raise Error, "Each check can only appear once in a save" if duplicate_targets.any?

    changes.each do |change|
      raise Error, "Unsupported check type" unless SOURCE_TYPES.include?(change.fetch(:source_type))
      validate_number!(change.fetch(:check_number), allow_blank: change.fetch(:source_type) == "non_employee_check")
    end
  end

  def validate_pay_period!
    raise Error, "Check numbers can only be edited for committed pay periods" unless pay_period.committed?
  end

  def validate_number!(number, allow_blank:)
    return if number.blank? && allow_blank
    raise Error, "Check number is required" if number.blank?
    raise Error, "Check numbers must use numbers only" unless number.match?(/\A\d+\z/)
    raise Error, "Check numbers must be greater than 0" if number.to_i < 1
    raise Error, "Check numbers cannot exceed #{MAX_CHECK_NUMBER.to_fs(:delimited)}" if number.to_i > MAX_CHECK_NUMBER
  end

  def load_and_lock_targets!
    payroll_ids = changes.filter_map { |change| change[:source_id] if change[:source_type] == "payroll_item" }
    non_employee_ids = changes.filter_map { |change| change[:source_id] if change[:source_type] == "non_employee_check" }

    payroll_items = pay_period.payroll_items.where(id: payroll_ids).includes(:employee).lock.index_by(&:id)
    non_employee_checks = pay_period.non_employee_checks.where(id: non_employee_ids).lock.index_by(&:id)
    if payroll_items.length != payroll_ids.uniq.length || non_employee_checks.length != non_employee_ids.uniq.length
      raise Error, "One or more checks no longer belong to this pay period"
    end

    targets = {}
    payroll_items.each_value do |item|
      raise Error, "Cannot change the number on a voided payroll check" if item.voided?
      raise Error, "No check number is assigned to #{item.employee&.full_name || 'a payroll check'}" if item.check_number.blank?
      targets[[ "payroll_item", item.id ]] = item
    end
    non_employee_checks.each_value do |check|
      raise Error, "Cannot change the number on a voided non-employee check" if check.voided?
      targets[[ "non_employee_check", check.id ]] = check
    end
    targets
  end

  def validate_final_numbers!(effective_changes)
    final_numbers = effective_changes.filter_map { |change| change[:check_number] }
    duplicate_number = final_numbers.group_by(&:itself).find { |_number, rows| rows.length > 1 }&.first
    raise Error, "Check number #{duplicate_number} is entered more than once" if duplicate_number

    payroll_ids = effective_changes.filter_map { |change| change[:source_id] if change[:source_type] == "payroll_item" }
    non_employee_ids = effective_changes.filter_map { |change| change[:source_id] if change[:source_type] == "non_employee_check" }

    used_payroll = PayrollItem.where(company_id: company.id, check_number: final_numbers).where.not(id: payroll_ids).pick(:check_number)
    raise Error, "Check number #{used_payroll} is already used by another payroll check" if used_payroll

    used_non_employee = NonEmployeeCheck.where(company_id: company.id, check_number: final_numbers).where.not(id: non_employee_ids).pick(:check_number)
    raise Error, "Check number #{used_non_employee} is already used by another non-employee check" if used_non_employee
  end

  def snapshot_targets(effective_changes, targets)
    effective_changes.each_with_object({}) do |change, snapshots|
      record = targets.fetch(target_key(change))
      snapshots[target_key(change)] = { record: record, old_number: record.check_number.to_s.presence }
    end
  end

  def record_change!(record, old_number, new_number, source_type)
    if source_type == "payroll_item"
      record.check_events.create!(
        user: actor,
        event_type: "renumbered",
        check_number: new_number,
        reason: audit_reason(old_number, new_number),
        ip_address: ip_address
      )
      record_audit!(record, old_number, new_number, "checks#check_number_updated", record.employee&.full_name)
    else
      record.edits.create!(
        edited_by: actor,
        before: { "check_number" => old_number },
        after: { "check_number" => new_number },
        changed_fields: [ "check_number" ],
        reason: reason
      )
      record_audit!(record, old_number, new_number, "non_employee_checks#updated", record.payable_to)
    end
  end

  def record_audit!(record, old_number, new_number, action, subject_name)
    AuditLog.record!(
      user: actor,
      organization_id: company.organization_id,
      company_id: company.id,
      action: action,
      record_type: record.is_a?(PayrollItem) ? "checks" : "non_employee_checks",
      record_id: record.id,
      subject_name: subject_name,
      metadata: {
        changed_fields: [ "check_number" ],
        before_values: { "check_number" => old_number },
        after_values: { "check_number" => new_number },
        reason: reason
      },
      ip_address: ip_address,
      user_agent: user_agent,
      request_id: request_id,
      event_category: "activity"
    )
  end

  def sync_documents!(snapshots)
    transmittal = pay_period.transmittal
    if transmittal
      payroll_numbers = sorted_numbers(pay_period.payroll_items.not_voided.where.not(check_number: nil).pluck(:check_number))
      non_employee_checks = pay_period.non_employee_checks.active.where.not(check_number: nil).pluck(:id, :check_number)
      all_numbers = sorted_numbers(payroll_numbers + non_employee_checks.map(&:last))
      transmittal.update!(
        check_number_first: all_numbers.first,
        check_number_last: all_numbers.last,
        payroll_check_numbers: payroll_numbers,
        non_employee_check_numbers: non_employee_checks.to_h.transform_keys(&:to_s)
      )
    end

    sheet = pay_period.check_signoff_sheet
    return unless sheet

    employee_changes = snapshots.values.filter_map do |snapshot|
      record = snapshot.fetch(:record)
      next unless record.is_a?(PayrollItem)
      [ "#{record.employee.last_name}, #{record.employee.first_name}", snapshot.fetch(:old_number), record.check_number ]
    end
    return if employee_changes.empty?

    entries = Array(sheet.entries).map do |entry|
      normalized = entry.stringify_keys
      change = employee_changes.find do |name, old_number, _new_number|
        normalized["name"].to_s == name && normalized["check_number"].to_s == old_number.to_s
      end
      change ? normalized.merge("check_number" => change.last) : normalized
    end
    sheet.update!(entries: entries)
  end

  def advance_company_sequence!(effective_changes)
    highest = effective_changes.filter_map { |change| change[:check_number]&.to_i }.max
    return unless highest && highest + 1 > company.next_check_number
    company.update!(next_check_number: highest + 1)
  end

  def sorted_numbers(numbers)
    numbers.map(&:to_s).sort_by { |number| [ number.match?(/\A\d+\z/) ? 0 : 1, number.to_i, number ] }
  end

  def audit_reason(old_number, new_number)
    "Check number changed from #{old_number || 'unassigned'} to #{new_number || 'unassigned'}: #{reason}"
  end

  def target_key(change)
    [ change.fetch(:source_type), change.fetch(:source_id) ]
  end
end
