# frozen_string_literal: true

# Durable intent fences ambiguous remote outcomes. A retry always uses the same
# source command, captured payroll rates, and destination adjustment.
class TimeTrackingLateHoursRun < ApplicationRecord
  belongs_to :company
  belongs_to :time_tracking_source
  belongs_to :origin_pay_period, class_name: "PayPeriod"
  belongs_to :adjustment_pay_period, class_name: "PayPeriod"
  belongs_to :created_by, class_name: "User"
  belongs_to :resolved_by, class_name: "User", optional: true

  validates :command_id, presence: true, uniqueness: { scope: :time_tracking_source_id }
  validates :state, inclusion: { in: %w[pending ambiguous reconciliation_required applied rejected cancelled] }
  validate :matching_ownership
  validate :immutable_intent, on: :update

  def wage_rates_for(employee)
    rate_snapshot.select { |rate| rate.fetch("employee_id") == employee.id }
      .map { |attributes| EmployeeWageRate.instantiate(attributes) }
  end

  def closed?
    state.in?(%w[rejected cancelled])
  end

  def unresolved?
    applied_at.nil? && !closed?
  end

  def transition!(next_state, actor:, reason: nil, evidence: nil)
    raise ArgumentError, "A closed late-hours operation cannot be reopened" if closed? && state != next_state
    previous = state
    attributes = { state: next_state }
    if evidence
      attributes.merge!(resolved_by: actor, resolved_at: Time.current, resolution: evidence)
    end
    update!(attributes)
    AuditLog.record!(user: actor, company_id: company_id, action: "late_hours#state_changed",
      record_type: self.class.name, record_id: id, subject_name: "Late-hours adjustment #{adjustment_pay_period_id}",
      event_category: "payroll", metadata: { from: previous, to: next_state, reason: reason,
        source_command_id: command_id, pay_period_id: adjustment_pay_period_id, evidence: evidence }.compact)
  end

  private

  def matching_ownership
    return if [ company, time_tracking_source, origin_pay_period, adjustment_pay_period ].any?(&:nil?)
    return if [ time_tracking_source, origin_pay_period, adjustment_pay_period ].all? { |record| record.company_id == company_id }

    errors.add(:base, "Late hours must belong to the same client and source")
  end

  def immutable_intent
    if (changed_attribute_names_to_save & %w[company_id time_tracking_source_id origin_pay_period_id adjustment_pay_period_id created_by_id command_id request_payload rate_snapshot selection_snapshot]).any? ||
        (batch_payload_in_database.present? && will_save_change_to_batch_payload?)
      errors.add(:base, "The late-hours destination, source selection and captured rates cannot change")
    end
  end
end
