# frozen_string_literal: true

# One read-only snapshot of a run's payment evidence, so a detail read does not
# ask each payroll row the same questions. Every answer matches the single-row
# query it replaces. Locked mutations never use this: they re-read under lock.
class PayrollPaymentEligibilityLookup
  def initialize(items)
    @items = items
    @ids = items.map(&:id)
  end

  def duplicate_check_linked?(item)
    duplicate_check_ids.include?(item.id)
  end

  def manual_payment_activity?(item)
    manual_payment_activity_ids.include?(item.id)
  end

  def pending_payment_resolution?(item)
    pending_payment_resolution_ids.include?(item.id)
  end

  def source_accounting_correction_linked?(item)
    source_accounting_correction_ids.include?(item.id)
  end

  def manual_cancellation_intent?(item)
    manual_cancellation_intent_ids.include?(item.id)
  end

  def source_lines(item)
    preload_allocation_evidence
    item.time_tracking_entry_allocations.to_a + financial_correction_links.fetch(item.id, [])
  end

  def active_manual_allocations(item)
    active_manual_allocation_rows.fetch(item.id, [])
  end

  # Rows are ordered by id, so the last match is the query's `.order(:id).last`.
  def original_receipt(item, row, number)
    original_receipts[[ item.id, row.time_tracking_import_id, row.source_time_entry_id, row.line_key, number ]]&.last
  end

  private

  def duplicate_check_ids
    @duplicate_check_ids ||= NonEmployeeCheckSupersession.where(payroll_item_id: @ids).pluck(:payroll_item_id).to_set
  end

  def manual_payment_activity_ids
    @manual_payment_activity_ids ||= manual_allocation_ids(TimeTrackingManualAllocation.with_payment_activity)
  end

  def pending_payment_resolution_ids
    @pending_payment_resolution_ids ||= manual_allocation_ids(TimeTrackingManualAllocation.pending_payment_resolution)
  end

  def manual_cancellation_intent_ids
    @manual_cancellation_intent_ids ||= manual_allocation_ids(TimeTrackingManualAllocation.with_payment_cancellation_intent)
  end

  def manual_allocation_ids(scope)
    scope.where(payroll_item_id: @ids).distinct.pluck(:payroll_item_id).to_set
  end

  def source_accounting_correction_ids
    @source_accounting_correction_ids ||= PayrollItem.source_accounting_correction_linked_ids(@ids)
  end

  # Only numeric-only lines read identity evidence, which needs the import.
  def preload_allocation_evidence
    return if @allocation_evidence_preloaded

    allocations = @items.flat_map { |item| item.time_tracking_entry_allocations.to_a }
    ActiveRecord::Associations::Preloader.new(records: allocations, associations: :time_tracking_source).call
    ActiveRecord::Associations::Preloader.new(records: allocations.select { |row| row.source_user_uuid.blank? },
      associations: [ :time_tracking_import, :time_tracking_legacy_identity_binding ]).call
    @allocation_evidence_preloaded = true
  end

  def financial_correction_links
    @financial_correction_links ||= TimeTrackingFinancialCorrectionLink.where(payroll_item_id: @ids)
      .includes(original_allocation: [ :time_tracking_import, :time_tracking_source, :time_tracking_legacy_identity_binding ])
      .to_a.group_by(&:payroll_item_id)
  end

  def active_manual_allocation_rows
    @active_manual_allocation_rows ||= TimeTrackingManualAllocation.not_voided.where(payroll_item_id: @ids)
      .includes(:time_tracking_source).to_a.group_by(&:payroll_item_id)
  end

  def original_receipts
    @original_receipts ||= AirePayrollEntryAcknowledgement
      .where(payroll_item_id: @ids, payment_method: "paper_check", status: TimeTracking::PaymentCancellationBridge::ORIGINAL_RECEIPT_STATUSES)
      .order(:id).to_a.group_by do |receipt|
        [ receipt.payroll_item_id, receipt.time_tracking_import_id, receipt.source_time_entry_id, receipt.source_line_key, receipt.payment_reference ]
      end
  end
end
