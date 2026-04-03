# frozen_string_literal: true

class PayPeriodTransmittalVersion < ApplicationRecord
  belongs_to :company
  belongs_to :pay_period
  belongs_to :pay_period_transmittal, inverse_of: :versions
  belongs_to :generated_by, class_name: "User", optional: true

  validates :version_number, presence: true, numericality: { greater_than: 0 }

  validate :json_shapes_are_valid

  def to_summary_payload
    {
      id: id,
      version_number: version_number,
      generated_at: generated_at,
      generated_from: generated_from,
      generated_by_id: generated_by_id,
      preparer_name: preparer_name,
      notes_count: notes.size,
      report_count: report_list.size,
      updated_check_range: [check_number_first, check_number_last].compact.join(" - ").presence
    }
  end

  def to_generator_options
    {
      preparer_name: preparer_name,
      notes: notes,
      report_list: report_list,
      check_number_first: check_number_first,
      check_number_last: check_number_last,
      non_employee_check_numbers: non_employee_check_numbers.to_h.transform_keys { |key| key.to_i }
    }
  end

  private

  def json_shapes_are_valid
    errors.add(:notes, "must be an array") unless notes.is_a?(Array)
    errors.add(:report_list, "must be an array") unless report_list.is_a?(Array)
    errors.add(:non_employee_check_numbers, "must be an object") unless non_employee_check_numbers.is_a?(Hash)
  end
end
