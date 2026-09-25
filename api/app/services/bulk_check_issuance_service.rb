# frozen_string_literal: true

class BulkCheckIssuanceService
  class InvalidSelectionError < StandardError; end

  def initialize(pay_period:, actor:, payroll_item_ids:, delivered_on:, delivery_method:, attestation:,
                 evidence_reference: nil, note: nil, ip_address: nil)
    @pay_period = pay_period
    @actor = actor
    @payroll_item_ids = normalize_ids(payroll_item_ids)
    @delivered_on = delivered_on
    @delivery_method = delivery_method
    @attestation = attestation
    @evidence_reference = evidence_reference
    @note = note
    @ip_address = ip_address
  end

  def call
    raise InvalidSelectionError, "Select at least one printed check" if payroll_item_ids.empty?

    PayPeriod.transaction do
      period = PayPeriod.lock.find(pay_period.id)
      raise InvalidSelectionError, "Check actions are only available for committed pay periods" unless period.committed?

      items = period.payroll_items.where(id: payroll_item_ids).order(:id).lock.to_a
      if items.length != payroll_item_ids.length
        raise InvalidSelectionError, "One or more selected checks do not belong to this pay period. Refresh and review the selection."
      end

      items.each do |item|
        unless item.effective_payment_delivery_method == "paper_check" && item.net_pay.to_d.positive? && item.check_number.present?
          raise InvalidSelectionError, "Check ##{item.check_number.presence || item.id} is not a payable paper check. Refresh and review the selection."
        end
        if item.voided? || item.check_printed_at.blank? || item.check_status == "delivered"
          raise InvalidSelectionError, "Check ##{item.check_number} is no longer ready to issue. Refresh and review the selection."
        end
      end

      items.each do |item|
        item.mark_delivered!(
          user: actor,
          delivered_on: delivered_on,
          delivery_method: delivery_method,
          attestation: attestation,
          evidence_reference: evidence_reference,
          note: note,
          ip_address: ip_address
        )
      end
      items
    end
  end

  private

  attr_reader :pay_period, :actor, :payroll_item_ids, :delivered_on, :delivery_method, :attestation,
    :evidence_reference, :note, :ip_address

  def normalize_ids(values)
    raise InvalidSelectionError, "Select at least one printed check" unless values.is_a?(Array)

    ids = values.map { |value| Integer(value.to_s, 10) }
    raise InvalidSelectionError, "Select each check only once" if ids.uniq.length != ids.length
    raise InvalidSelectionError, "Check selection is invalid" unless ids.all?(&:positive?)

    ids
  rescue ArgumentError, TypeError
    raise InvalidSelectionError, "Check selection is invalid"
  end
end
