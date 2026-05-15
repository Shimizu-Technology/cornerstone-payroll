# frozen_string_literal: true

class CheckNumberCorrectionService
  class Error < StandardError; end

  attr_reader :payroll_item, :new_check_number, :actor, :ip_address, :reason

  def initialize(payroll_item:, new_check_number:, actor:, ip_address: nil, reason: nil)
    @payroll_item = payroll_item
    @new_check_number = normalize_check_number(new_check_number)
    @actor = actor
    @ip_address = ip_address
    @reason = reason.to_s.strip.presence
  end

  def call
    validate_state!

    old_check_number = payroll_item.check_number.to_s
    return payroll_item if old_check_number == new_check_number

    ApplicationRecord.transaction do
      company.lock!
      payroll_item.lock!

      validate_uniqueness!

      payroll_item.update!(check_number: new_check_number)
      advance_next_check_number!

      payroll_item.check_events.create!(
        user: actor,
        event_type: "renumbered",
        check_number: new_check_number,
        reason: audit_reason(old_check_number),
        ip_address: ip_address
      )

      sync_transmittal!
      sync_signoff_sheet!(old_check_number)
    end

    payroll_item.reload
  rescue ActiveRecord::RecordNotUnique
    raise Error, "Check number #{new_check_number} is already in use for this company"
  end

  private

  def validate_state!
    raise Error, "Check number is required" if new_check_number.blank?
    raise Error, "Check number must be numeric" unless new_check_number.match?(/\A\d+\z/)
    raise Error, "Check number must be greater than 0" if new_check_number.to_i < 1
    raise Error, "Check number cannot exceed 9,999,999" if new_check_number.to_i > 9_999_999
    raise Error, "Check number corrections are only available for committed pay periods" unless pay_period.committed?
    raise Error, "Cannot change the number on a voided check" if payroll_item.voided?
    raise Error, "No check number assigned to this payroll item" if payroll_item.check_number.blank?
  end

  def validate_uniqueness!
    if PayrollItem.where(company_id: company.id, check_number: new_check_number).where.not(id: payroll_item.id).exists?
      raise Error, "Check number #{new_check_number} is already used by another payroll check"
    end

    if NonEmployeeCheck.where(company_id: company.id, check_number: new_check_number).exists?
      raise Error, "Check number #{new_check_number} is already used by a non-employee check"
    end
  end

  def advance_next_check_number!
    next_number = new_check_number.to_i + 1
    return unless next_number > company.next_check_number

    company.update!(next_check_number: next_number)
  end

  def sync_transmittal!
    transmittal = pay_period.transmittal
    return unless transmittal

    numbers = transmittal_check_numbers
    transmittal.update!(
      check_number_first: numbers.first,
      check_number_last: numbers.last,
      non_employee_check_numbers: synced_non_employee_check_numbers(transmittal)
    )
  end

  def sync_signoff_sheet!(old_check_number)
    sheet = pay_period.check_signoff_sheet
    return unless sheet

    name = "#{payroll_item.employee.last_name}, #{payroll_item.employee.first_name}"
    updated = false
    entries = Array(sheet.entries).map do |entry|
      normalized = entry.stringify_keys
      if normalized["name"].to_s == name && normalized["check_number"].to_s == old_check_number
        updated = true
        normalized.merge("check_number" => new_check_number)
      else
        normalized
      end
    end

    sheet.update!(entries: entries) if updated
  end

  def transmittal_check_numbers
    (payroll_check_numbers + non_employee_check_numbers)
      .sort_by { |number| [number.to_s.to_i, number.to_s] }
  end

  def payroll_check_numbers
    pay_period.payroll_items
      .not_voided
      .where.not(check_number: nil)
      .pluck(:check_number)
  end

  def non_employee_check_numbers
    pay_period.non_employee_checks
      .active
      .where.not(check_number: nil)
      .pluck(:check_number)
  end

  def synced_non_employee_check_numbers(transmittal)
    numbers = (transmittal.non_employee_check_numbers || {}).stringify_keys
    pay_period.non_employee_checks.active.find_each do |check|
      if check.check_number.present?
        numbers[check.id.to_s] = check.check_number
      else
        numbers.delete(check.id.to_s)
      end
    end
    numbers
  end

  def audit_reason(old_check_number)
    base = "Check number changed from #{old_check_number} to #{new_check_number}"
    reason.present? ? "#{base}: #{reason}" : base
  end

  def normalize_check_number(value)
    value.to_s.strip.presence
  end

  def pay_period
    payroll_item.pay_period
  end

  def company
    pay_period.company
  end
end
