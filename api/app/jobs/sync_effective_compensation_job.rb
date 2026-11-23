# frozen_string_literal: true

# Activates scheduled pay changes (M3-4). Payroll reads rates from the history
# tables by pay period end date, so this only refreshes the cache columns
# (employees.pay_rate and the employee_wage_rates rows) that profile screens,
# exports and older readers show as "today's" rate.
#
# The scheduled scan covers employees across all companies.
class SyncEffectiveCompensationJob < ApplicationJob
  self.rls_mode = :system

  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 3

  def perform(as_of: nil)
    date = as_of.present? ? Date.iso8601(as_of.to_s) : PayrollBusinessClock.today
    Current.with_isolated_actor(AuditActor.system_job(self)) { sync_employees(date) }
  end

  private

  def sync_employees(as_of)
    failures = employee_ids_needing_sync(as_of).filter_map do |employee_id|
      Employee.transaction(requires_new: true) do
        company_id = Employee.where(id: employee_id).pick(:company_id)
        Company.lock.find_by(id: company_id)
        employee = Employee.lock.find_by(id: employee_id)
        EmployeeCompensationChangeService.sync_cache!(employee, as_of: as_of) if employee
      end
      nil
    rescue StandardError => error
      Rails.logger.error("Compensation cache sync failed for employee_id=#{employee_id} (#{error.class})")
      Rails.error.report(error, handled: true, context: { employee_id: employee_id })
      employee_id
    end
    raise "Compensation cache sync failed for employee IDs: #{failures.join(', ')}" if failures.any?
  end

  # Employees with a version that started on or before today and is newer than
  # the last cache refresh window: anything that took effect since yesterday,
  # plus any row whose cache already disagrees with today's version.
  def employee_ids_needing_sync(as_of)
    starting = EmployeeCompensationChange.where(effective_on: (as_of - 7)..as_of).distinct.pluck(:employee_id) +
      EmployeeWageRateVersion.where(effective_on: (as_of - 7)..as_of).distinct.pluck(:employee_id)
    stale_pay = EmployeeCompensationChange.joins(:employee)
      .covering(as_of)
      .where(EmployeeCompensationChange::SNAPSHOT_ATTRIBUTES.map do |field|
        "employees.#{field} IS DISTINCT FROM employee_compensation_changes.#{field}"
      end.join(" OR "))
      .distinct.pluck(:employee_id)
    stale_rates = EmployeeWageRateVersion.joins(:employee_wage_rate)
      .covering(as_of)
      .where(<<~SQL.squish)
        employee_wage_rates.label <> employee_wage_rate_versions.label
        OR employee_wage_rates.rate IS DISTINCT FROM employee_wage_rate_versions.rate
        OR employee_wage_rates.is_primary <> employee_wage_rate_versions.is_primary
        OR employee_wage_rates.active <> employee_wage_rate_versions.active
      SQL
      .distinct.pluck(:employee_id)
    (starting + stale_pay + stale_rates).uniq.sort
  end
end
