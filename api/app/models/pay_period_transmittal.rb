# frozen_string_literal: true

class PayPeriodTransmittal < ApplicationRecord
  DEFAULT_REPORT_LIST = [
    "Payroll Summary by Employee",
    "Deductions and Contributions Report",
    "Paycheck History",
    "Retirement Plans Report",
    "Employee Installment Loan Report"
  ].freeze

  DEFAULT_NOTES = [
    "EFTPS payment to be done by client",
    "401K upload to be submitted by client"
  ].freeze

  belongs_to :company
  belongs_to :pay_period, inverse_of: :transmittal_state
  has_many :versions,
           -> { order(generated_at: :desc, id: :desc) },
           class_name: "PayPeriodTransmittalVersion",
           dependent: :destroy,
           inverse_of: :pay_period_transmittal

  validates :pay_period_id, uniqueness: true
  before_validation :normalize_payload!

  validate :json_shapes_are_valid

  def self.default_attributes_for(pay_period)
    items = pay_period.payroll_items.where(voided: false)
    check_numbers = items.where.not(check_number: nil).pluck(:check_number).sort_by(&:to_i)
    non_employee_check_numbers = pay_period.non_employee_checks.active.order(:id).each_with_object({}) do |check, memo|
      memo[check.id.to_s] = check.check_number.to_s.presence || ""
    end

    total_fit = items.sum(:withholding_tax).to_f
    emp_ss = items.sum(:social_security_tax).to_f
    er_ss = items.sum(:employer_social_security_tax).to_f
    emp_med = items.sum(:medicare_tax).to_f
    er_med = items.sum(:employer_medicare_tax).to_f
    total_fica = emp_ss + er_ss + emp_med + er_med

    auto_notes = []
    if total_fica.positive?
      auto_notes << "EFTPS Payment (Social Security & Medicare): #{format_currency(total_fica)} — to be deducted from bank account"
    end
    if total_fit.positive?
      auto_notes << "FIT Deposit Total: #{format_currency(total_fit)} — check to Treasurer of Guam for DRT"
    end

    {
      preparer_name: "Cornerstone Tax Services",
      notes: auto_notes + DEFAULT_NOTES,
      report_list: DEFAULT_REPORT_LIST,
      check_number_first: check_numbers.first,
      check_number_last: check_numbers.last,
      non_employee_check_numbers: non_employee_check_numbers
    }
  end

  def assign_state(attributes)
    assign_attributes(normalized_state_attributes(attributes))
    self
  end

  def normalized_state_attributes(attributes)
    attrs = (attributes || {}).deep_symbolize_keys

    {
      preparer_name: attrs[:preparer_name].to_s.presence,
      notes: normalize_string_array(attrs[:notes]),
      report_list: normalize_string_array(attrs[:report_list]),
      check_number_first: attrs[:check_number_first].to_s.presence,
      check_number_last: attrs[:check_number_last].to_s.presence,
      non_employee_check_numbers: normalize_non_employee_check_numbers(attrs[:non_employee_check_numbers])
    }
  end

  def to_payload
    {
      id: id,
      pay_period_id: pay_period_id,
      preparer_name: preparer_name,
      notes: notes,
      report_list: report_list,
      check_number_first: check_number_first,
      check_number_last: check_number_last,
      non_employee_check_numbers: non_employee_check_numbers,
      updated_at: updated_at,
      last_generated_at: versions.maximum(:generated_at)
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

  def create_version_snapshot!(generated_by: nil, generated_from: nil)
    versions.create!(
      company: company,
      pay_period: pay_period,
      version_number: next_version_number,
      generated_at: Time.current,
      generated_by: generated_by,
      generated_from: generated_from,
      preparer_name: preparer_name,
      notes: notes,
      report_list: report_list,
      check_number_first: check_number_first,
      check_number_last: check_number_last,
      non_employee_check_numbers: non_employee_check_numbers
    )
  end

  private

  def json_shapes_are_valid
    errors.add(:notes, "must be an array") unless notes.is_a?(Array)
    errors.add(:report_list, "must be an array") unless report_list.is_a?(Array)
    errors.add(:non_employee_check_numbers, "must be an object") unless non_employee_check_numbers.is_a?(Hash)
  end


  def next_version_number
    (versions.maximum(:version_number) || 0) + 1
  end

  def normalize_payload!
    self.notes = normalize_string_array(notes)
    self.report_list = normalize_string_array(report_list)
    self.non_employee_check_numbers = normalize_non_employee_check_numbers(non_employee_check_numbers)
    self.preparer_name = preparer_name.to_s.presence
    self.check_number_first = check_number_first.to_s.presence
    self.check_number_last = check_number_last.to_s.presence
  end

  def normalize_string_array(values)
    Array(values).filter_map do |value|
      cleaned = value.to_s.strip
      cleaned if cleaned.present?
    end
  end

  def normalize_non_employee_check_numbers(values)
    values.to_h.each_with_object({}) do |(key, value), memo|
      cleaned = value.to_s.strip
      next if cleaned.blank?

      memo[key.to_s] = cleaned
    end
  end

  def self.format_currency(value)
    number = format("%.2f", value.to_f)
    whole, decimal = number.split('.')
    delimited_whole = whole.reverse.scan(/.{1,3}/).join(',').reverse
    "$#{delimited_whole}.#{decimal}"
  end
end
