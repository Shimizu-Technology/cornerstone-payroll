# frozen_string_literal: true

class W2FilingReadiness < ApplicationRecord
  STATUSES = %w[draft preflight_passed filing_ready].freeze

  belongs_to :company
  belongs_to :marked_ready_by, class_name: "User", optional: true

  validates :year, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :company_id, uniqueness: { scope: :year }
end
