# frozen_string_literal: true

require "set"

class Company < ApplicationRecord
  CHECK_STOCK_TYPES = %w[bottom_check top_check first_hawaiian_4up].freeze
  PAYROLL_INTAKE_SOURCE_TYPES = %w[spike_email].freeze

  belongs_to :organization
  belongs_to :active_printer_profile, class_name: "PrinterProfile", optional: true

  has_many :departments, dependent: :destroy
  has_many :employees, dependent: :destroy
  has_many :time_tracking_sources, dependent: :destroy
  has_many :pay_periods, dependent: :destroy
  has_many :payroll_items, dependent: :restrict_with_error
  has_many :payroll_field_definitions, dependent: :destroy
  has_many :deduction_types, dependent: :destroy
  has_many :company_ytd_totals, dependent: :destroy
  has_many :users, dependent: :destroy
  has_many :user_invitations, dependent: :destroy
  has_many :non_employee_checks, dependent: :destroy
  has_many :check_print_runs, dependent: :restrict_with_error
  has_many :general_transmittals, dependent: :destroy
  has_many :invoice_recipients, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :invoice_chat_sessions, dependent: :destroy
  has_many :employee_loans, dependent: :destroy
  has_many :client_documents, dependent: :destroy
  has_many :employee_change_requests, dependent: :destroy
  has_many :form500_filings, dependent: :destroy
  has_many :pay_component_tax_rules, dependent: :restrict_with_error
  has_many :payroll_liability_postings, dependent: :restrict_with_error
  has_many :payroll_liability_entries, dependent: :restrict_with_error
  has_many :quarterly_compliance_packets, dependent: :destroy
  has_one :payroll_reminder_config, dependent: :destroy
  has_many :payroll_reminder_logs, dependent: :destroy
  # Printer profiles are organization-scoped so every operator in the same
  # accounting firm can share the same physical printer calibration.

  before_validation :normalize_blanks

  validates :name, presence: true
  validates :ein, uniqueness: true, allow_blank: true
  validates :pay_frequency, inclusion: { in: %w[biweekly weekly semimonthly monthly] }
  validates :check_stock_type, inclusion: { in: CHECK_STOCK_TYPES }
  validates :check_offset_x, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validates :check_offset_y, numericality: { greater_than_or_equal_to: -2.0, less_than_or_equal_to: 2.0 }
  validate :check_layout_config_must_be_hash
  validate :payroll_intake_source_types_are_supported

  scope :active, -> { where(active: true) }

  # ---------------------------------------------------------------------------
  # Check number sequencing — thread-safe via row-level lock
  # ---------------------------------------------------------------------------

  # Assign check numbers to a set of payroll_items (unsaved or without check #).
  # All assignments happen inside a single locked transaction — no collisions.
  # @param items [ActiveRecord::Relation or Array<PayrollItem>] items needing a check #
  # @return [Integer] the number of check numbers assigned
  def assign_check_numbers!(items)
    items = items.to_a
    return 0 if items.empty?

    assigned = 0
    self.class.transaction do
      lock!  # SELECT … FOR UPDATE on this company row
      next_number = next_check_number
      window_size = [ items.size * 2, 100 ].max
      window_end = next_number + window_size - 1
      issued_numbers = issued_check_numbers_in_range(next_number, window_end)
      assignments = {}

      items.each do |item|
        while issued_numbers.include?(next_number.to_s)
          next_number += 1
          if next_number > window_end
            window_end = next_number + window_size - 1
            issued_numbers.merge(issued_check_numbers_in_range(next_number, window_end))
          end
        end
        check_number = next_number.to_s
        assignments[item.id] = check_number
        issued_numbers.add(check_number)
        next_number += 1
      end

      timestamp = Time.current
      rows = items.map do |item|
        {
          id: item.id,
          company_id: item.company_id,
          employee_id: item.employee_id,
          employment_type: item.employment_type,
          pay_period_id: item.pay_period_id,
          pay_rate: item.pay_rate,
          created_at: item.created_at,
          updated_at: timestamp,
          check_number: assignments.fetch(item.id)
        }
      end
      PayrollItem.upsert_all(
        rows,
        unique_by: :id,
        update_only: [ :check_number, :updated_at ],
        record_timestamps: false
      )

      assigned = items.size
      update_column(:next_check_number, next_number)
    end
    assigned
  rescue ActiveRecord::StatementInvalid => e
    if e.message.include?("index_payroll_items_on_check_number") ||
       e.message.include?("index_payroll_items_on_company_check_number") ||
       e.message.downcase.include?("unique")
      raise ArgumentError, "Check number collision detected while assigning checks. Please verify company check settings and retry."
    end
    raise
  end

  # Reserve exactly one check number (for reprint flow).
  # @return [String] the newly reserved check number string
  def next_check_number!
    reserved = nil
    self.class.transaction do
      lock!
      next_number = next_check_number
      window_size = 100
      window_end = next_number + window_size - 1
      issued_numbers = issued_check_numbers_in_range(next_number, window_end)

      while issued_numbers.include?(next_number.to_s)
        next_number += 1
        if next_number > window_end
          window_end = next_number + window_size - 1
          issued_numbers.merge(issued_check_numbers_in_range(next_number, window_end))
        end
      end

      reserved = next_number.to_s
      update_column(:next_check_number, next_number + 1)
    end
    reserved
  end

  def full_address
    [ address_line1, address_line2, "#{city}, #{state} #{zip}" ].compact_blank.join("\n")
  end

  def first_hawaiian_4up_checks?
    check_stock_type == "first_hawaiian_4up"
  end

  def payroll_intake_source_enabled?(source_type)
    payroll_intake_source_types.include?(source_type.to_s)
  end

  private

  def normalize_blanks
    self.ein = nil if ein.blank?
    self.payroll_intake_source_types = Array(payroll_intake_source_types).compact_blank.map(&:to_s).uniq
  end

  def check_layout_config_must_be_hash
    return if check_layout_config.is_a?(Hash)

    errors.add(:check_layout_config, "must be a JSON object")
  end

  def payroll_intake_source_types_are_supported
    unsupported = Array(payroll_intake_source_types) - PAYROLL_INTAKE_SOURCE_TYPES
    return if unsupported.empty?

    errors.add(:payroll_intake_source_types, "contains unsupported source type(s): #{unsupported.join(', ')}")
  end

  def issued_check_numbers_in_range(start_number, end_number)
    numbers = (start_number..end_number).map(&:to_s)
    payroll_numbers = PayrollItem.where(company_id: id, check_number: numbers).pluck(:check_number)
    non_employee_numbers = NonEmployeeCheck.where(company_id: id, check_number: numbers).pluck(:check_number)

    Set.new(payroll_numbers + non_employee_numbers)
  end
end
