# frozen_string_literal: true

class NonEmployeeCheckLineItem < ApplicationRecord
  belongs_to :non_employee_check

  before_validation :normalize_fields

  validates :description, presence: true
  validates :amount, presence: true, numericality: { greater_than: 0 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  default_scope { order(:position, :id) }

  private

  def normalize_fields
    self.description = description.to_s.strip
    self.reference_number = reference_number.to_s.strip.presence
    self.service_period = service_period.to_s.strip.presence
  end
end
