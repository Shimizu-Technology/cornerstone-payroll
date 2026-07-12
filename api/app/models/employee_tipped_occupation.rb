# frozen_string_literal: true

class EmployeeTippedOccupation < ApplicationRecord
  belongs_to :employee

  validates :occupation_code, format: { with: /\A\d{3}\z/, message: "must be a three-digit Treasury occupation code" }
  validates :effective_from, presence: true
  validate :effective_to_not_before_effective_from
  validate :effective_dates_do_not_overlap

  scope :effective_during, ->(range) {
    where("effective_from <= ? AND (effective_to IS NULL OR effective_to >= ?)", range.end, range.begin)
  }

  private

  def effective_to_not_before_effective_from
    return if effective_to.blank? || effective_from.blank? || effective_to >= effective_from

    errors.add(:effective_to, "cannot be before the effective start date")
  end

  def effective_dates_do_not_overlap
    return if employee_id.blank? || effective_from.blank?

    range_end = effective_to || Date.new(9999, 12, 31)
    overlap = self.class.where(employee_id: employee_id, occupation_code: occupation_code)
                        .where.not(id: id)
                        .where("effective_from <= ? AND COALESCE(effective_to, DATE '9999-12-31') >= ?", range_end, effective_from)
    errors.add(:base, "occupation code has an overlapping effective period") if overlap.exists?
  end
end
