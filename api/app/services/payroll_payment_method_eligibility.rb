# frozen_string_literal: true

require "set"

# Shared by the read-only UI preview and the mutation's locked validation.
# A delivery preference does not prove that money was transferred.
class PayrollPaymentMethodEligibility
  ACTIVITY_EVENTS = %w[prepared printed batch_downloaded delivered].freeze

  # Read-only serializers share this lookup. The locked mutation builds fresh
  # activity when it has no shared snapshot. A nil number protects legacy runs.
  def self.print_activity_for_period(period)
    activity = Hash.new { |hash, id| hash[id] = Set.new }
    period.check_print_runs.pluck(:manifest).each do |manifest|
      manifest.each do |entry|
        ids = []
        key = entry["key"].to_s.match(/\Apayroll_item:([1-9]\d*)\z/)
        ids << key[1].to_i if key
        id = entry["source_id"].to_s
        ids << id.to_i if entry["source_type"] == "payroll_item" && id.match?(/\A[1-9]\d*\z/)
        number = entry["check_number"].blank? ? nil : entry["check_number"].to_s
        ids.uniq.each { |item_id| activity[item_id] << number }
      end
    end
    activity
  end

  def initialize(item, print_activity: nil)
    @item = item
    @print_activity = print_activity
  end

  def call
    target = item.effective_payment_delivery_method == "direct_deposit" ? "paper_check" : "direct_deposit"
    result = {
      eligible: false, mode: "blocked", reason: nil, target_method: target,
      original_check_number: item.check_number,
      requires_unpaid_confirmation: item.pay_period.committed?, requires_check_cancellation: false
    }
    reason = if item.voided? || item.pay_period.voided?
      "This payment is voided. Its delivery method cannot be changed."
    elsif !item.pay_period.status.in?(%w[draft calculated approved committed])
      "Payment methods cannot be changed in this payroll's current state."
    elsif !item.net_pay.to_d.positive?
      "There is no net payment to change. Print the earnings statement instead; no check number is needed."
    elsif item.direct_deposit_payment_confirmation.present?
      "A bank payment has already been confirmed. Its delivery method cannot be changed."
    elsif item.duplicate_check_linked?
      "This payment is linked to a duplicate check record. Review that reconciliation before changing its delivery method."
    elsif (blocker = TimeTracking::PaymentCancellationBridge.blocker_for(item, check_activity: check_has_activity?))
      blocker
    elsif CheckReconciliationStatus.for(item) == "cleared"
      "This check has cleared. Resolve the bank clearing evidence before changing its delivery method."
    elsif !item.pay_period.committed? && target == "direct_deposit" && item.check_number.present?
      "Remove the draft check number before choosing direct deposit."
    elsif target == "paper_check" && item.check_number.present?
      "A check number is already assigned. Review this record before changing its delivery method."
    end
    return result.merge(reason: reason) if reason

    retirement = item.pay_period.committed? && target == "direct_deposit" && check_has_activity?
    result.merge(
      eligible: true, mode: retirement ? "retire_check" : "simple",
      requires_check_cancellation: retirement,
      reason: retirement ? "Cancel or recover the original check and record evidence before changing to direct deposit. Do not continue while the original check could still be paid." : nil
    )
  end

  def check_has_activity?
    return true if item.time_tracking_manual_allocations.where.not(status: "voided")
      .where("status = 'issued' OR payment_issue_intent <> '{}'::jsonb").exists?
    return true if item.check_prepared?

    events = item.check_events
    event_activity = if events.loaded?
      events.any? do |event|
        ACTIVITY_EVENTS.include?(event.event_type) && [ nil, "", item.check_number ].include?(event.check_number)
      end
    else
      events.where(event_type: ACTIVITY_EVENTS, check_number: [ nil, "", item.check_number ]).exists?
    end
    return true if event_activity

    activity = @print_activity || self.class.print_activity_for_period(item.pay_period)
    numbers = activity.fetch(item.id, nil)
    numbers && (numbers.include?(nil) || numbers.include?(item.check_number.to_s)) || false
  end

  private

  attr_reader :item
end
