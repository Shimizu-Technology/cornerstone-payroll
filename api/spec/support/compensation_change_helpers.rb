# frozen_string_literal: true

# Pay rates are effective-dated (M3-4): spec setup that changes an employee's
# pay goes through EmployeeCompensationChangeService like application code.
# Without an effective_on, the change starts on the service's default date
# (the day after the employee's last approved or committed payroll), which is
# when a direct overwrite used to reach payroll.
module CompensationChangeHelpers
  def change_compensation!(employee, effective_on: nil, historical_correction: false, actor: AuditActor.system_job("Compensation spec setup"), **attributes)
    attributes = attributes.stringify_keys
    pay_rate = attributes.key?("pay_rate") ? attributes.delete("pay_rate") : EmployeeCompensationChangeService::UNCHANGED
    basis = attributes.extract!(*EmployeeCompensationChangeService::BASIS_ATTRIBUTES)
    # Some legacy payroll fixtures simulate changing tax class in place,
    # while real tax-class changes create a linked successor employee.
    employee.allow_tax_classification_change = true if basis.key?("employment_type")
    employee.update!(attributes) if attributes.any?
    EmployeeCompensationChangeService.new(
      employee: employee, actor: actor, source: "staff", reason: "Spec setup", effective_on: effective_on,
      historical_correction: historical_correction, pay_rate: pay_rate, basis: basis
    ).call!
    employee
  end

  def change_wage_rate!(wage_rate, effective_on: nil, historical_correction: false, actor: AuditActor.system_job("Compensation spec setup"), **attributes)
    EmployeeCompensationChangeService.new(
      employee: wage_rate.employee, actor: actor, source: "staff", reason: "Spec setup", effective_on: effective_on,
      historical_correction: historical_correction, wage_rate_edits: [ attributes.merge(id: wage_rate.id) ]
    ).call!
    wage_rate.reload
  end
end

RSpec.configure { |config| config.include CompensationChangeHelpers }
