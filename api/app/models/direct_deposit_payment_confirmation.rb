# frozen_string_literal: true

# Evidence that a transfer was actually completed outside Cornerstone.
# A pay-stub download and a committed payroll are not payment evidence.
class DirectDepositPaymentConfirmation < ApplicationRecord
  belongs_to :payroll_item
  belongs_to :user

  validates :settled_on, :bank_reference, presence: true
  validate :valid_payroll_item
  validate :valid_actor
  validate :not_future_dated

  before_update :prevent_mutation
  before_destroy :prevent_mutation
  after_create :record_aire_entry_lifecycle
  after_create_commit :dispatch_aire_entry_lifecycle
  after_create_commit :dispatch_aire_manual_allocations

  private

  def valid_payroll_item
    return if payroll_item.blank?

    errors.add(:payroll_item, "must be committed direct-deposit payroll") unless
      payroll_item.pay_period.committed? && !payroll_item.pay_period.voided? &&
      !payroll_item.voided? && payroll_item.effective_payment_delivery_method == "direct_deposit" &&
      payroll_item.net_pay.to_d.positive?
  end

  def valid_actor
    return if payroll_item.blank? || user.blank?

    errors.add(:user, "must belong to the payroll organization") unless
      user.organization_id == payroll_item.company.organization_id
  end

  def not_future_dated
    errors.add(:settled_on, "cannot be in the future") if settled_on.present? && settled_on > PayrollBusinessClock.today
  end

  def prevent_mutation
    errors.add(:base, "Direct-deposit payment evidence is append-only")
    throw :abort
  end

  def record_aire_entry_lifecycle
    @aire_entry_acknowledgement_ids = payroll_item.time_tracking_entry_allocations
      .includes(:time_tracking_import)
      .select { |row| row.time_tracking_import.finalized_batch? }
      .group_by { |row| [ row.time_tracking_import_id, row.source_time_entry_id ] }
      .map do |(_import_id, source_time_entry_id), rows|
        AirePayrollEntryAcknowledgement.record_from_rows!(
          rows: rows,
          source_event_key: "direct_deposit_confirmation:#{id}:#{source_time_entry_id}",
          status: "payment_issued",
          occurred_at: created_at,
          payroll_item_id: payroll_item_id,
          payment_method: "direct_deposit",
          payment_reference: bank_reference
        ).id
      end
  end

  def dispatch_aire_entry_lifecycle
    AirePayrollEntryAcknowledgement.dispatch_pending!(ids: @aire_entry_acknowledgement_ids) if @aire_entry_acknowledgement_ids.present?
  end

  def dispatch_aire_manual_allocations
    payroll_item.time_tracking_manual_allocations.where.not(status: "voided").find_each do |allocation|
      AireManualAllocationSyncJob.perform_later(allocation.id)
    end
  end
end
