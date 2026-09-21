# frozen_string_literal: true

# Ethan uses the same three wages as the other AIRE CFIs. Preserve the old
# Aerial Tours row for history, but do not offer it for new approved time.
class AlignVerifiedAireCfiWages < ActiveRecord::Migration[8.0]
  EXPECTED = {
    "Flight Hours" => BigDecimal("30.00"),
    "Ground Instruction Hours" => BigDecimal("30.00"),
    "Admin Duties" => BigDecimal("10.00")
  }.freeze

  def up
    company = Company.find_by(id: 2)
    if company.nil?
      raise "AIRE payroll company is missing" if Rails.env.production?

      return
    end
    raise "AIRE payroll company changed" unless company.name == "AIRE Services"

    employee = company.employees.find_by(id: 108)
    unless employee&.full_name == "Ethan Calaunan" && employee.active? &&
           employee.employment_type == "hourly" && employee.pay_rate == BigDecimal("30.00")
      raise "Ethan's verified CFI payroll profile changed"
    end

    rates = employee.employee_wage_rates.to_a
    old = rates.find { |rate| rate.label == "Aerial Tours" }
    raise "Ethan's old Aerial Tours wage changed" unless old && old.rate == BigDecimal("30.00")

    used = employee.payroll_items.any? do |item|
      Array(item.wage_rate_hours).any? { |hours| hours["employee_wage_rate_id"].to_i == old.id }
    end
    raise "Ethan's Aerial Tours wage has payroll history; review before changing it" if used

    current = rates.select(&:active?).to_h { |rate| [ rate.label, rate.rate ] }
    return if current == EXPECTED && !old.active?
    raise "Ethan has unexpected active wage rates" unless current == { "Aerial Tours" => BigDecimal("30.00") }

    old.update!(active: false, is_primary: false)
    EXPECTED.each do |label, rate|
      employee.employee_wage_rates.create!(label: label, rate: rate, active: true, is_primary: label == "Flight Hours")
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Verified wage changes may already have been used for payroll"
  end
end
