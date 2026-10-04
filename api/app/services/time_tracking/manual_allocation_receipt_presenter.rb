# frozen_string_literal: true

module TimeTracking
  # A current payroll item may have been reissued since its AIRE allocation was
  # paid. Display the immutable source receipt, never the item's replacement
  # check number or scheduled payday, as evidence for that allocation.
  class ManualAllocationReceiptPresenter
    def initialize(source:, payload:)
      @source = source
      rows = payload.is_a?(Hash) ? payload["manual_allocations"] : nil
      @receipts = Array(rows).select { |row| row.is_a?(Hash) }
        .group_by { |row| row["id"].to_s }
    end

    def call(allocation)
      return unless allocation.time_tracking_source_id == @source.id && allocation.remote_allocation_id.present?

      candidates = @receipts[allocation.remote_allocation_id.to_s]
      return unless candidates&.one?

      receipt = candidates.first
      return unless matching_allocation?(allocation, receipt)
      return unless receipt["status"] == "issued"
      return unless receipt["payment_reference"].is_a?(String) && receipt["payment_reference"].strip.present?
      return unless receipt["payment_reference"].length <= 200

      effective_on = Date.iso8601(receipt.fetch("payment_effective_on"))
      return unless effective_on.iso8601 == receipt["payment_effective_on"]

      {
        reference: receipt["payment_reference"],
        effective_on: effective_on.iso8601,
        provenance: "aire_issued_receipt"
      }
    rescue ArgumentError, TypeError, KeyError
      nil
    end

    private

    def matching_allocation?(allocation, receipt)
      {
        "external_pay_period_id" => allocation.pay_period_id.to_s,
        "external_payroll_item_id" => allocation.payroll_item_id.to_s,
        "source_time_entry_id" => allocation.source_time_entry_id.to_s,
        "source_user_uuid" => allocation.source_user_uuid,
        "original_work_date" => allocation.original_work_date.iso8601
      }.all? { |key, value| receipt[key].to_s == value } &&
        matching_hours?(receipt["regular_hours"], allocation.regular_hours) &&
        matching_hours?(receipt["overtime_hours"], allocation.overtime_hours)
    end

    def matching_hours?(value, expected)
      return false unless value.is_a?(String) || value.is_a?(Numeric)

      hours = BigDecimal(value.to_s)
      hours.finite? && hours >= 0 && hours == expected
    end
  end
end
