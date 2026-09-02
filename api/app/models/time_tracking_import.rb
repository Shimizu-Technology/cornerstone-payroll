# frozen_string_literal: true

class TimeTrackingImport < ApplicationRecord
  STATUSES = %w[previewed applied failed].freeze
  SOURCE_PROCESSING_STATUSES = %w[imported committed payment_issued payment_failed].freeze
  SOURCE_PAYMENT_STATUSES = %w[payment_issued payment_failed].freeze
  SOURCE_PROCESSING_STATUS_RANK = {
    "imported" => 10,
    "committed" => 20,
    "payment_issued" => 30,
    "payment_failed" => 40
  }.freeze
  FINALIZED_IMMUTABLE_ATTRIBUTES = %w[
    pay_period_id time_tracking_source_id start_date end_date fetch_start_date fetch_end_date
    source_payload_hash external_batch_id external_batch_checksum contract_version source_cutoff_at
    raw_payload processed_payload warnings
  ].freeze

  belongs_to :pay_period
  belongs_to :time_tracking_source
  belongs_to :applied_by, class_name: "User", optional: true
  has_many :aire_payroll_acknowledgements, dependent: :restrict_with_error

  validates :status, inclusion: { in: STATUSES }
  validates :start_date, :end_date, :fetch_start_date, :fetch_end_date, :source_payload_hash, presence: true
  validates :external_batch_id, :external_batch_checksum, :contract_version, :source_cutoff_at, presence: true, if: :finalized_batch?
  validates :external_batch_checksum, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :source_processing_status, inclusion: { in: SOURCE_PROCESSING_STATUSES }, allow_nil: true
  validate :finalized_batch_snapshot_is_immutable, on: :update

  def finalized_batch?
    external_batch_id.present? || external_batch_checksum.present? || contract_version.present? || source_cutoff_at.present?
  end

  def record_source_processing_sync!(status:, synced_at:)
    with_lock do
      next_status = next_source_processing_status(status)
      return false if source_processing_status.present? && next_status == source_processing_status && status != source_processing_status

      update!(
        source_processing_status: next_status,
        source_processing_synced_at: synced_at,
        source_processing_sync_error: nil
      )
    end
    true
  end

  def record_source_processing_failure!(status:, message:)
    with_lock do
      return false if source_processing_status_supersedes?(status)

      update!(source_processing_sync_error: message)
    end
    true
  end

  private

  def next_source_processing_status(status)
    return status if status.in?(SOURCE_PAYMENT_STATUSES)
    return source_processing_status if source_processing_status.in?(SOURCE_PAYMENT_STATUSES)

    current_rank = SOURCE_PROCESSING_STATUS_RANK.fetch(source_processing_status, -1)
    SOURCE_PROCESSING_STATUS_RANK.fetch(status) >= current_rank ? status : source_processing_status
  end

  def source_processing_status_supersedes?(status)
    return false if source_processing_status.blank?
    return true if source_processing_status == status && source_processing_synced_at.present?
    return true if source_processing_status.in?(SOURCE_PAYMENT_STATUSES) && !status.in?(SOURCE_PAYMENT_STATUSES)
    return false if status.in?(SOURCE_PAYMENT_STATUSES)

    SOURCE_PROCESSING_STATUS_RANK.fetch(source_processing_status, -1) > SOURCE_PROCESSING_STATUS_RANK.fetch(status)
  end

  def finalized_batch_snapshot_is_immutable
    return unless finalized_batch_persisted?

    changed_fields = FINALIZED_IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    return if changed_fields.empty?

    errors.add(:base, "Finalized payroll batch provenance and payload cannot be changed after preview creation")
  end

  def finalized_batch_persisted?
    %w[external_batch_id external_batch_checksum contract_version source_cutoff_at].any? do |attribute|
      attribute_in_database(attribute).present?
    end
  end
end
