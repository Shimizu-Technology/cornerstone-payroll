# frozen_string_literal: true

class EmployeeIntakeExceptionReviewService
  class Error < StandardError; end

  def self.call!(employee:, actor:, attributes:)
    raise Error, "Manager or administrator access required" unless actor.organization_admin? || actor.manager?
    raise Error, "Employee is outside your company access" unless actor.can_access_company?(employee.company_id)
    attrs = attributes.to_h.symbolize_keys
    Employee.transaction do
      employee.company.lock!
      employee.lock!
      raise Error, "This employee has no intake exception" if employee.intake_exception.blank?
      exception = employee.intake_exception.deep_dup
      if attrs.key?(:follow_up_due_on)
        exception["follow_up_due_on"] = Date.iso8601(attrs[:follow_up_due_on].to_s).iso8601
      end
      if ActiveModel::Type::Boolean.new.cast(attrs[:confirm_payroll_setup])
        reason = attrs[:reason].to_s.strip
        raise Error, "Explain the payroll setup confirmation" if reason.blank?
        eligible_from = attrs[:payroll_eligible_from].presence || employee.hire_date&.iso8601
        raise Error, "Confirm the first eligible payroll date" if eligible_from.blank?
        eligible_from = Date.iso8601(eligible_from.to_s)
        raise Error, "Eligible date must have a year between 1900 and next year" unless eligible_from.year.between?(1900, Date.current.year + 1)
        if employee.w2_employee? && !employee.w4_election_on(eligible_from)
          unless ActiveModel::Type::Boolean.new.cast(attrs[:acknowledge_default_withholding])
            raise Error, "Explicitly acknowledge default withholding when no election is available"
          end
          EmployeeW4ElectionChangeService.new(employee: employee, actor: actor,
            source: "default_withholding", reason: reason,
            attributes: { w4_effective_on: eligible_from, filing_status: "single", allowances: 0,
              additional_withholding: 0, w4_dependent_credit: 0, w4_step2_multiple_jobs: false,
              w4_step4a_other_income: 0, w4_step4b_deductions: 0, w4_form_version: 2020,
              w4_signed_on: nil, w4_source_reference: "Manager approved default withholding; employee election outstanding" }).call!
        end
        exception["payroll_setup_confirmed_by_id"] = actor.id
        exception["payroll_setup_confirmed_by_name"] = actor.name
        exception["payroll_setup_confirmation_reason"] = reason
        employee.intake_payroll_eligible_from = eligible_from
        employee.intake_payroll_confirmed_at = Time.current
      end
      employee.intake_exception = exception
      employee.save!
      AuditLog.record!(user: actor, company_id: employee.company_id, action: "employee_intake_exception#review",
        record_type: "employees", record_id: employee.id,
        metadata: { reason: attrs[:reason], follow_up_due_on: exception["follow_up_due_on"],
          payroll_eligible_from: employee.intake_payroll_eligible_from, payroll_setup_confirmed_at: employee.intake_payroll_confirmed_at })
    end
    employee
  rescue ArgumentError
    raise Error, "Provide valid dates in YYYY-MM-DD format"
  end
end
