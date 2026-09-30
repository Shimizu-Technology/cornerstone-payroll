# frozen_string_literal: true

class AirePayrollEntryAcknowledgement < ApplicationRecord
  LINE_CONTRACT_VERSION = "2.0"
  STATUSES = %w[imported committed payment_prepared payment_issued payment_failed payment_voided].freeze
  REDISPATCH_AFTER = 30.minutes

  belongs_to :time_tracking_import
  belongs_to :payroll_item
  belongs_to :check_event, optional: true

  validates :source_event_key, :event_id, :source_time_entry_id, :source_user_id, :status, :occurred_at, presence: true
  validates :source_event_key, :event_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :contract_version, inclusion: { in: [ LINE_CONTRACT_VERSION ] }, allow_nil: true
  validates :source_line_key, :source_kind, presence: true, if: :line_contract?
  validates :source_kind, inclusion: { in: TimeTrackingEntryAllocation::SOURCE_KINDS }, if: :line_contract?
  validates :total_hours, :regular_hours, :overtime_hours, numericality: true, if: :line_contract?
  validate :line_contract_shape

  scope :undelivered, -> { where(delivered_at: nil) }
  scope :due_for_dispatch, -> { undelivered.where("enqueued_at IS NULL OR enqueued_at < ?", REDISPATCH_AFTER.ago) }

  def self.record_for_import!(time_tracking_import:, status:, occurred_at:, payment_method: nil, payment_reference: nil, source_event_prefix: "import", payroll_item_id: nil, allocations: nil)
    unless allocations
      scope = time_tracking_import.time_tracking_entry_allocations.includes(:payroll_item)
      scope = scope.where(payroll_item_id: payroll_item_id) if payroll_item_id.present?
      allocations = scope.to_a
    end
    allocations = allocations.to_a
    allocations = allocations.select { |allocation| allocation.payroll_item_id == payroll_item_id } if payroll_item_id.present?
    allocations.map do |allocation|
      record_from_rows!(
        rows: [ allocation ],
        source_event_key: "#{source_event_prefix}:#{time_tracking_import.id}:#{status}:#{allocation.payroll_item_id}:#{allocation.source_time_entry_id}:#{allocation.line_key}",
        status: status,
        occurred_at: occurred_at,
        payroll_item_id: allocation.payroll_item_id,
        payment_method: payment_method,
        payment_reference: payment_reference
      )
    end
  end

  def self.record_for_check_event!(check_event:, status:)
    item = check_event.payroll_item
    item.time_tracking_entry_allocations.includes(:time_tracking_import).map do |row|
      record_from_rows!(
        rows: [ row ],
        source_event_key: "check_event:#{check_event.id}:#{row.source_time_entry_id}:#{row.line_key}:#{status}",
        status: status,
        occurred_at: check_event.created_at,
        payroll_item_id: item.id,
        check_event_id: check_event.id,
        payment_method: "paper_check",
        payment_reference: check_event.check_number
      )
    end
  end

  def self.record_from_rows!(rows:, source_event_key:, status:, occurred_at:, payroll_item_id:, check_event_id: nil, payment_method: nil, payment_reference: nil)
    rows = rows.to_a
    raise ArgumentError, "AIRE entry acknowledgement requires exactly one payable line" unless rows.one?

    row = rows.first
    create_or_find_by!(source_event_key: source_event_key) do |ack|
      ack.event_id = "cornerstone:entry:#{SecureRandom.uuid}"
      ack.time_tracking_import_id = row.time_tracking_import_id
      ack.payroll_item_id = payroll_item_id
      ack.check_event_id = check_event_id
      ack.source_time_entry_id = row.source_time_entry_id
      ack.source_user_id = row.source_user_id
      ack.source_user_uuid = row.source_user_uuid
      ack.contract_version = LINE_CONTRACT_VERSION
      ack.source_line_key = row.line_key
      ack.source_kind = row.source_kind
      ack.total_hours = row.total_hours
      ack.regular_hours = row.regular_hours
      ack.overtime_hours = row.overtime_hours
      ack.status = status
      ack.occurred_at = occurred_at
      ack.payment_method = payment_method
      ack.payment_reference = payment_reference
    end
  end

  def self.dispatch_pending!(ids: nil)
    scope = due_for_dispatch
    scope = scope.where(id: ids) if ids.present?
    scope.find_each(&:dispatch!)
  end

  def dispatch!
    with_lock do
      return false if delivered_at.present?
      return false if enqueued_at.present? && enqueued_at >= REDISPATCH_AFTER.ago

      AirePayrollEntryStatusSyncJob.perform_later(id)
      update!(enqueued_at: Time.current, last_error: nil)
    end
    true
  rescue StandardError => e
    update_columns(last_error: e.message, updated_at: Time.current) if persisted?
    false
  end

  def mark_delivered!(at:)
    update!(delivered_at: at, last_error: nil)
  end

  def record_delivery_failure!(message)
    update!(last_error: message)
  end

  def line_contract?
    contract_version == LINE_CONTRACT_VERSION
  end

  private

  def line_contract_shape
    line_fields = [ source_line_key, source_kind, total_hours, regular_hours, overtime_hours ]
    if contract_version.nil?
      errors.add(:contract_version, "is required for payable-line fields") if line_fields.any?(&:present?)
      return
    end
    return unless line_contract? && total_hours.present? && regular_hours.present? && overtime_hours.present?
    return if total_hours == regular_hours + overtime_hours

    errors.add(:total_hours, "must equal regular plus overtime hours")
  end
end
