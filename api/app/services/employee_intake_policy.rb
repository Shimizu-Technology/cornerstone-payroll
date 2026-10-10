# frozen_string_literal: true

class EmployeeIntakePolicy
  MAX_WINDOW = 24.hours
  DEFERABLE_FIELDS = %w[ssn contractor_ein hire_date address_line1 city state zip withholding_election].freeze

  def self.enabled?(company)
    company.employee_intake_expires_at.present? && company.employee_intake_expires_at > Time.current
  end

  def self.settings(company, actor)
    {
      enabled: enabled?(company), expires_at: company.employee_intake_expires_at,
      reason: company.employee_intake_reason,
      enabled_by_name: User.find_by(id: company.employee_intake_enabled_by_id)&.name,
      can_manage: actor.organization_admin?
    }
  end

  # Caller must hold the company lock through employee persistence.
  def self.prepare!(employee, actor:)
    return unless employee.new_record?
    entry_enabled = enabled?(employee.company)
    employee.require_initial_w4_effective_on = !entry_enabled
    return unless entry_enabled

    missing = missing_fields(employee)
    return if missing.empty?

    employee.intake_exception = {
      "deferred_fields" => missing, "reason" => employee.company.employee_intake_reason,
      "authorized_by_id" => employee.company.employee_intake_enabled_by_id,
      "created_by_id" => actor&.id, "follow_up_owner_id" => actor&.id,
      "authorized_by_name" => User.find_by(id: employee.company.employee_intake_enabled_by_id)&.name,
      "created_by_name" => actor&.name, "follow_up_owner_name" => actor&.name,
      "follow_up_due_on" => (Date.current + 7.days).iso8601,
      "created_at" => Time.current.iso8601
    }
  end

  def self.missing_fields(employee)
    fields = %w[hire_date address_line1 city state zip].select { |field| employee.public_send(field).blank? }
    identifier = employee.business_contractor? ? employee.contractor_ein : employee.ssn_encrypted
    fields << (employee.business_contractor? ? "contractor_ein" : "ssn") if identifier.blank?
    if employee.w2_employee?
      elections = employee.employee_w4_elections.to_a
      default_only = elections.any? && elections.all? { |election| election.source == "default_withholding" }
      fields << "withholding_election" if employee.w4_effective_on.blank? || default_only
    end
    fields
  end

  def self.summary(employee)
    exception = employee.intake_exception.presence
    missing = exception ? missing_fields(employee) : []
    {
      profile_incomplete: missing.any?, missing_fields: missing,
      exception: exception && {
        reason: exception["reason"],
        authorized_by_name: exception["authorized_by_name"],
        created_by_name: exception["created_by_name"],
        follow_up_owner_id: exception["follow_up_owner_id"],
        follow_up_owner_name: exception["follow_up_owner_name"],
        follow_up_due_on: exception["follow_up_due_on"],
        payroll_eligible_from: employee.intake_payroll_eligible_from,
        payroll_setup_confirmed_at: employee.intake_payroll_confirmed_at,
        payroll_setup_confirmed_by_name: exception["payroll_setup_confirmed_by_name"]
      }
    }
  end

  def self.payroll_ready?(employee, period_end)
    employee.intake_exception.blank? || (
      employee.intake_payroll_confirmed_at.present? &&
      employee.intake_payroll_eligible_from.present? && employee.intake_payroll_eligible_from <= period_end &&
      (employee.contractor? || employee.w4_election_on(period_end).present?)
    )
  end
end
