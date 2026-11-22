# frozen_string_literal: true

# Pay rates are effective-dated (M3-4): spec setup that changes an employee's
# pay goes through EmployeeCompensationChangeService like application code.
# Without an effective_on, the change starts on the service's default date
# (the day after the employee's last approved or committed payroll), which is
# when a direct overwrite used to reach payroll.
module CompensationChangeHelpers
  def change_compensation!(employee, effective_on: nil, historical_correction: false, **attributes)
    attributes = attributes.stringify_keys
    pay_rate = attributes.key?("pay_rate") ? attributes.delete("pay_rate") : EmployeeCompensationChangeService::UNCHANGED
    employee.update!(attributes) if attributes.any?
    EmployeeCompensationChangeService.new(
      employee: employee, actor: nil, source: "staff", reason: "Spec setup", effective_on: effective_on,
      historical_correction: historical_correction, pay_rate: pay_rate
    ).call!
    employee
  end

  def change_wage_rate!(wage_rate, effective_on: nil, historical_correction: false, **attributes)
    EmployeeCompensationChangeService.new(
      employee: wage_rate.employee, actor: nil, source: "staff", reason: "Spec setup", effective_on: effective_on,
      historical_correction: historical_correction, wage_rate_edits: [ attributes.merge(id: wage_rate.id) ]
    ).call!
    wage_rate.reload
  end
end

RSpec.configure { |config| config.include CompensationChangeHelpers }
