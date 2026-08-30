# frozen_string_literal: true

class TimeTrackingImport < ApplicationRecord
  STATUSES = %w[previewed applied failed].freeze
  FINALIZED_IMMUTABLE_ATTRIBUTES = %w[
    pay_period_id time_tracking_source_id start_date end_date fetch_start_date fetch_end_date
    source_payload_hash external_batch_id external_batch_checksum contract_version source_cutoff_at
    raw_payload processed_payload warnings
  ].freeze

  belongs_to :pay_period
  belongs_to :time_tracking_source
  belongs_to :applied_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :start_date, :end_date, :fetch_start_date, :fetch_end_date, :source_payload_hash, presence: true
  validates :external_batch_id, :external_batch_checksum, :contract_version, :source_cutoff_at, presence: true, if: :finalized_batch?
  validates :external_batch_checksum, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :finalized_batch_snapshot_is_immutable, on: :update

  def finalized_batch?
    external_batch_id.present? || external_batch_checksum.present? || contract_version.present? || source_cutoff_at.present?
  end

  private

  def finalized_batch_snapshot_is_immutable
    return unless finalized_batch?

    changed_fields = FINALIZED_IMMUTABLE_ATTRIBUTES.select { |attribute| will_save_change_to_attribute?(attribute) }
    return if changed_fields.empty?

    errors.add(:base, "Finalized payroll batch provenance and payload cannot be changed after preview creation")
  end
end
