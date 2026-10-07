# frozen_string_literal: true

# Existing payroll rows must retain the method staff already reviewed, including
# legacy/import rows that previously inherited a mutable employee preference.
class EmployeePaymentDefaultService
  attr_reader :reapproval_pay_period_ids

  def initialize(employee:, method:, actor:, ip_address: nil, record_audit: true)
    @employee = employee
    @method = method.presence
    @actor = actor
    @ip_address = ip_address
    @record_audit = record_audit
    @reapproval_pay_period_ids = []
  end

  def call
    Employee.transaction do
      Company.lock.find(employee.company_id)
      employee.reload
      next employee if employee.payment_delivery_method == method

      old_method = employee.payment_delivery_method.presence || "paper_check"
      inherited = employee.payroll_items.where(payment_delivery_method: nil)
        .joins(:pay_period).where(pay_periods: { status: %w[draft calculated approved] })
        .order(:pay_period_id, :id)
      inherited.each do |item|
        period = PayPeriod.lock.find(item.pay_period_id)
        item.lock!
        next if item.payment_delivery_method.present? || period.committed?

        item.update!(payment_delivery_method: old_method)
        @reapproval_pay_period_ids << period.id if period.approved?
        PayrollPaymentMethodService.refresh_review!(period: period, actor: actor)
      end
      employee.lock!
      employee.update!(payment_delivery_method: method)
      AuditLog.record!(
        user: actor, company_id: employee.company_id,
        action: "employee#payment_delivery_default_changed", record_type: "Employee",
        record_id: employee.id, subject_name: employee.full_name,
        metadata: { from: old_method, to: method, existing_runs_preserved: true }, ip_address: ip_address
      ) if @record_audit
      employee
    end
  end

  private

  attr_reader :employee, :method, :actor, :ip_address
end
