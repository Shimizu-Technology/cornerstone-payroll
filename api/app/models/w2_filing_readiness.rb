# frozen_string_literal: true

class W2FilingReadiness < ApplicationRecord
  STATUSES = %w[draft preflight_passed filing_ready].freeze

  belongs_to :company
  belongs_to :marked_ready_by, class_name: "User", optional: true

  validates :year,
    presence: true,
    numericality: {
      only_integer: true,
      greater_than: 2000,
      less_than_or_equal_to: ->(_record) { Date.current.year + 1 }
    }
  validates :status, inclusion: { in: STATUSES }
  validates :company_id, uniqueness: { scope: :year }
end
