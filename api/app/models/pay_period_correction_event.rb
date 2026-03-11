# frozen_string_literal: true

# CPR-71: Immutable audit record for every payroll correction action.
#
# Records are append-only. Never updated or deleted.
# financial_snapshot is captured at the moment of the action so the
# audit trail remains accurate regardless of future changes.
class PayPeriodCorrectionEvent < ApplicationRecord
  ACTION_TYPES = %w[
    void_initiated
    correction_run_created
    correction_run_committed
  ].freeze

  belongs_to :pay_period
  belongs_to :resulting_pay_period, class_name: "PayPeriod", optional: true
  belongs_to :actor, class_name: "User", foreign_key: :actor_id, optional: true
  belongs_to :company

  validates :action_type, presence: true,
                          inclusion: { in: ACTION_TYPES }
  validates :reason, presence: true
  validates :company_id, presence: true

  scope :chronological, -> { order(created_at: :asc) }
  scope :for_action, ->(type) { where(action_type: type) }

  # Build a financial snapshot hash from a pay period and its items.
  # Called before any mutation so the snapshot reflects state at time of action.
  def self.build_financial_snapshot(pay_period)
    items = pay_period.payroll_items.where(voided: false).to_a
    {
      "gross_pay"            => items.sum { |i| i.gross_pay.to_f }.round(2),
      "net_pay"              => items.sum { |i| i.net_pay.to_f }.round(2),
      "employee_count"       => items.size,
      "total_withholding"    => items.sum { |i| i.withholding_tax.to_f }.round(2),
      "total_social_security"=> items.sum { |i| i.social_security_tax.to_f }.round(2),
      "total_medicare"       => items.sum { |i| i.medicare_tax.to_f }.round(2),
      "total_employer_ss"    => items.sum { |i| i.employer_social_security_tax.to_f }.round(2),
      "total_employer_medicare" => items.sum { |i| i.employer_medicare_tax.to_f }.round(2)
    }
  end

  # Convenience factory — creates and persists the event in one call.
  def self.record!(
    action_type:,
    pay_period:,
    actor:,
    reason:,
    resulting_pay_period: nil,
    extra_metadata: {},
    financial_snapshot_from: :pay_period
  )
    snapshot_source =
      if financial_snapshot_from == :resulting_pay_period && resulting_pay_period.present?
        resulting_pay_period
      else
        pay_period
      end

    snapshot = build_financial_snapshot(snapshot_source)

    create!(
      action_type:             action_type,
      pay_period:              pay_period,
      resulting_pay_period:    resulting_pay_period,
      actor:                   actor,
      actor_name:              actor&.name || "System",
      company_id:              pay_period.company_id,
      reason:                  reason,
      financial_snapshot:      snapshot,
      metadata:                extra_metadata
    )
  end
end
