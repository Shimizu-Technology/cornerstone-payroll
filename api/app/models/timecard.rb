class Timecard < ApplicationRecord
  belongs_to :company
  belongs_to :pay_period, optional: true
  has_many :punch_entries, -> { order(:card_day) }, dependent: :destroy

  enum :ocr_status, { pending: 0, processing: 1, complete: 2, failed: 3, reviewed: 4 }

  validates :image_hash, uniqueness: { scope: :company_id }, allow_nil: true

  scope :for_period, lambda { |period_start, period_end|
    where("period_start <= ? AND period_end >= ?", period_end, period_start)
  }

  def reviewable?
    complete? || reviewed?
  end

  def reprocessable?
    complete? || reviewed? || failed?
  end

  def clear_review_audit!
    update_columns(ocr_status: self.class.ocr_statuses[:complete], reviewed_by_name: nil, reviewed_at: nil)
  end
end
