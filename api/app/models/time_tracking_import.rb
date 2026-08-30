# frozen_string_literal: true

class TimeTrackingImport < ApplicationRecord
  STATUSES = %w[previewed applied failed].freeze

  belongs_to :pay_period
  belongs_to :time_tracking_source
  belongs_to :applied_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :start_date, :end_date, :fetch_start_date, :fetch_end_date, :source_payload_hash, presence: true
  validates :external_batch_id, :external_batch_checksum, :contract_version, :source_cutoff_at, presence: true, if: :finalized_batch?
  validates :external_batch_checksum, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true

  def finalized_batch?
    external_batch_id.present? || external_batch_checksum.present? || contract_version.present? || source_cutoff_at.present?
  end
end
