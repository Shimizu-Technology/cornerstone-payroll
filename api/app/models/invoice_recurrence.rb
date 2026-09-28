# frozen_string_literal: true

class InvoiceRecurrence < ApplicationRecord
  INTERVAL_UNITS = %w[week month].freeze

  belongs_to :organization
  belongs_to :source_invoice, class_name: "Invoice"
  belongs_to :created_by, class_name: "User", optional: true
  has_many :generated_invoices, class_name: "Invoice", dependent: :restrict_with_error
  include FinanceBookOwned

  validates :interval_unit, inclusion: { in: INTERVAL_UNITS }
  validates :interval_count, numericality: { only_integer: true, greater_than: 0 }
  validates :due_after_days, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :start_on, :next_on, presence: true
  validate :valid_time_zone
  validates :source_invoice_id, uniqueness: { conditions: -> { where(active: true) }, message: "already has an active recurrence" }, if: :active?
  validate :source_belongs_to_organization
  validate :source_belongs_to_book
  validate :ends_after_start

  scope :due, ->(today = Date.current) { where(active: true).where("next_on <= ?", today) }

  def occurrence_date(index = occurrence_index)
    interval_unit == "month" ? start_on.advance(months: index * interval_count) : start_on + (index * interval_count * 7)
  end

  def advance!
    next_index = occurrence_index + 1
    next_date = occurrence_date(next_index)
    update!(occurrence_index: next_index, next_on: next_date, active: ends_on.blank? || next_date <= ends_on)
  end

  def resume!
    with_lock do
      local_today = ActiveSupport::TimeZone[time_zone].today
      next_index = occurrence_index
      next_index += 1 while occurrence_date(next_index) < local_today
      next_date = occurrence_date(next_index)
      raise ArgumentError, "Recurrence has already ended" if ends_on.present? && next_date > ends_on

      update!(occurrence_index: next_index, next_on: next_date, active: true)
    end
  end

  private

  def finance_book_parent
    source_invoice
  end

  def source_belongs_to_book
    return if source_invoice.blank? || finance_book.blank? || source_invoice.finance_book_id == finance_book_id

    errors.add(:source_invoice, "must belong to the same financial book")
  end

  def source_belongs_to_organization
    return if source_invoice.blank? || organization.blank? || source_invoice.organization_id == organization_id

    errors.add(:source_invoice, "must belong to the same organization")
  end

  def ends_after_start
    return if ends_on.blank? || start_on.blank? || ends_on >= start_on

    errors.add(:ends_on, "cannot precede the start date")
  end

  def valid_time_zone
    errors.add(:time_zone, "is invalid") unless time_zone.is_a?(String) && time_zone.present? && ActiveSupport::TimeZone[time_zone]
  end
end
