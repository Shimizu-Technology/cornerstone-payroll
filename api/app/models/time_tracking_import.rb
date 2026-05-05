# frozen_string_literal: true

class TimeTrackingImport < ApplicationRecord
  STATUSES = %w[previewed applied failed].freeze

  belongs_to :pay_period
  belongs_to :time_tracking_source
  belongs_to :applied_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :start_date, :end_date, :fetch_start_date, :fetch_end_date, :source_payload_hash, presence: true
end
