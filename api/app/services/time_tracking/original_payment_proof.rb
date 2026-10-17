# frozen_string_literal: true

module TimeTracking
  class OriginalPaymentProof
    ERROR = "Original payment not verified; review or replace unissued payroll first"

    def self.call(item, financial_target: nil)
      raise ArgumentError, ERROR unless item.pay_period.committed? && !item.pay_period.voided? && !item.voided? && item.net_pay.to_d.positive?
      if item.effective_payment_delivery_method == "direct_deposit"
        confirmation = item.direct_deposit_payment_confirmation
        verified = confirmation && if financial_target.is_a?(PaidCorrectionTarget)
                                     confirmation.historical_evidence_valid?
                                   else
                                     confirmation.valid?
                                   end
        raise ArgumentError, ERROR unless verified
        return { method: "direct_deposit", confirmation: confirmation.attributes }
      end
      raise ArgumentError, ERROR unless item.effective_payment_delivery_method == "paper_check" && item.check_number.present?
      events = item.check_events.where(check_number: item.check_number).order(:created_at, :id).to_a
      head = events.reverse.find { |event| event.event_type.in?(%w[delivered voided replaced]) }
      verified = head&.event_type == "delivered" && if financial_target.is_a?(PaidCorrectionTarget)
                                                      head.historical_delivery_evidence_valid?
                                                    else
                                                      head.valid?
                                                    end
      raise ArgumentError, ERROR unless verified && CheckReconciliationStatus.for(item).in?(%w[issued cleared])
      { method: "paper_check", check_number: item.check_number, events: events.map(&:attributes),
        reconciliation: item.check_reconciliation_events.where(check_number: item.check_number).order(:created_at, :id).map(&:attributes) }
    end
  end
end
