# frozen_string_literal: true

# Read-only: saved paychecks require an explicit operator removal, never cleanup
# during calculation. Keep the date boundaries in Employee.eligible_for_period.
class PayrollRunEligibility
  def initialize(pay_period)
    @period = pay_period
  end

  def payload
    return [] unless @period.regular_run? && @period.status.in?(%w[draft calculated approved])

    eligible = Employee.eligible_for_period(@period.start_date, @period.end_date).select(:id)
    status_affected = Employee.where(status: %w[inactive terminated]).or(
      Employee.where(id: EmployeeStatusEvent.where(event_type: %w[deactivated terminated])
        .where("effective_date <= ?", @period.start_date).select(:employee_id))
    )
    workers = status_affected.where(id: @period.payroll_items.select(:employee_id)).where.not(id: eligible)
      .includes(:employee_status_events).order(:last_name, :first_name)
    workers = workers.to_a
    return [] if workers.empty?

    items = @period.payroll_items.where(employee_id: workers.map(&:id)).includes(:employee, :fica_basis_proof, :time_tracking_entry_allocations,
      :time_tracking_manual_allocations, :aire_payroll_entry_acknowledgements).index_by(&:employee_id)
    workers.map do |worker|
      event = worker.employee_status_events.select { |row| row.event_type.in?(%w[deactivated terminated]) && row.effective_date <= @period.start_date }
        .max_by { |row| [ row.effective_date, row.id ] }
      status = event&.resulting_status || worker.status
      date = event&.effective_date || worker.termination_date
      reason = if status.in?(%w[inactive terminated])
        "#{worker.full_name} is #{status}#{date ? " from #{date.strftime('%b %-d, %Y')}" : ''}"
      else
        "#{worker.full_name} is not eligible for this run's dates"
      end
      { employee_id: worker.id, reason: reason, status: status, effective_date: date, resolution: items.fetch(worker.id).status_removal_resolution }
    end
  end
end
