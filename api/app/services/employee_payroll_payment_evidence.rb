# frozen_string_literal: true

# A saved payroll result and a prepared/printed check do not establish issue.
# Historical owner approvals must be recorded through reconciliation first.
class EmployeePayrollPaymentEvidence
  def initialize(item)
    @item = item
  end

  def call
    return evidence("voided", "Voided") if @item.voided? || @item.pay_period.voided?

    if @item.effective_payment_delivery_method == "direct_deposit"
      confirmation = @item.direct_deposit_payment_confirmation
      return evidence("issued", "Transfer confirmed", confirmation.settled_on) if confirmation

      return evidence("unissued", "Transfer not confirmed")
    end

    delivery = @item.check_events.select do |event|
      event.event_type == "delivered" && event.check_number == @item.check_number
    end.max_by { |event| [ event.created_at, event.id ] }
    return evidence("issued", "Check delivered", delivery.effective_on) if delivery
    return evidence("printed", "Printed · delivery not recorded") if @item.check_printed_at.present?
    return evidence("prepared", "Prepared · not issued") if @item.check_prepared?

    evidence("unissued", "Issue not recorded")
  end

  private

  def evidence(status, label, effective_on = nil)
    { status: status, label: label, effective_on: effective_on }
  end
end
