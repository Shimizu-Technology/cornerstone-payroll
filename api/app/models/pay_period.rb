# frozen_string_literal: true

class PayPeriod < ApplicationRecord
  belongs_to :company
  has_many :payroll_items, dependent: :destroy

  validates :start_date, presence: true
  validates :end_date, presence: true
  validates :pay_date, presence: true
  validates :status, inclusion: { in: %w[draft calculated approved committed] }
  validate :end_date_after_start_date
  validate :pay_date_after_end_date

  scope :draft, -> { where(status: "draft") }
  scope :calculated, -> { where(status: "calculated") }
  scope :approved, -> { where(status: "approved") }
  scope :committed, -> { where(status: "committed") }
  scope :for_year, ->(year) { where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31)) }

  def draft?
    status == "draft"
  end

  def calculated?
    status == "calculated"
  end

  def approved?
    status == "approved"
  end

  def committed?
    status == "committed"
  end

  def can_edit?
    !committed?
  end

  def period_description
    "#{start_date.strftime('%m/%d/%Y')} - #{end_date.strftime('%m/%d/%Y')}"
  end

  private

  def end_date_after_start_date
    return unless start_date && end_date

    if end_date <= start_date
      errors.add(:end_date, "must be after start date")
    end
  end

  def pay_date_after_end_date
    return unless pay_date && end_date

    if pay_date < end_date
      errors.add(:pay_date, "must be on or after end date")
    end
  end
end
