# frozen_string_literal: true

class EmployeeChangeRequest < ApplicationRecord
  PERMITTED_EMPLOYEE_UPDATE_KEYS = %i[
    first_name
    middle_name
    last_name
    email
    ssn_encrypted
    date_of_birth
    hire_date
    termination_date
    department_id
    job_title
    employment_type
    salary_type
    pay_rate
    pay_frequency
    filing_status
    allowances
    additional_withholding
    w4_dependent_credit
    w4_step2_multiple_jobs
    w4_step4a_other_income
    w4_step4b_deductions
    retirement_rate
    roth_retirement_rate
    employer_retirement_match_rate
    employer_roth_match_rate
    business_name
    contractor_ein
    contractor_type
    contractor_pay_type
    w9_on_file
    address_line1
    address_line2
    city
    state
    zip
    phone
    status
  ].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :requested_by, class_name: "User", optional: true
  belongs_to :reviewed_by, class_name: "User", optional: true

  enum :status, { pending: 0, approved: 1, rejected: 2 }

  validates :proposed_changes, presence: true
  validates :requested_by, presence: true, on: :create

  scope :recent_first, -> { order(created_at: :desc) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }

  def apply!(actor:, review_notes: nil)
    ensure_pending!

    ActiveRecord::Base.transaction do
      apply_proposed_changes!
      update!(
        status: :approved,
        reviewed_by: actor,
        review_notes: review_notes,
        reviewed_at: Time.current
      )
    end
  end

  def reject!(actor:, review_notes:)
    ensure_pending!

    update!(
      status: :rejected,
      reviewed_by: actor,
      review_notes: review_notes,
      reviewed_at: Time.current
    )
  end

  private

  def ensure_pending!
    return if pending?

    errors.add(:status, "must be pending before review actions can be applied")
    raise ActiveRecord::RecordInvalid, self
  end

  def apply_proposed_changes!
    attrs = normalize_proposed_changes(proposed_changes.deep_symbolize_keys)
    wage_rates = attrs.delete(:wage_rates)
    validate_supported_change_keys!(attrs.keys)
    safe_attrs = attrs.slice(*PERMITTED_EMPLOYEE_UPDATE_KEYS)
    validate_department_scope!(safe_attrs)

    employee.update!(safe_attrs) if safe_attrs.present?
    return unless wage_rates.present?

    EmployeeWageRateSyncService.new(employee: employee, wage_rates: wage_rates).sync!
  end

  def normalize_proposed_changes(attrs)
    return attrs unless attrs[:ssn].present?

    attrs.except(:ssn).merge(ssn_encrypted: attrs[:ssn])
  end

  def validate_supported_change_keys!(keys)
    unsupported_keys = keys.map(&:to_sym) - PERMITTED_EMPLOYEE_UPDATE_KEYS
    return if unsupported_keys.empty?

    errors.add(:proposed_changes, "contains unsupported fields: #{unsupported_keys.join(', ')}")
    raise ActiveRecord::RecordInvalid, self
  end

  def validate_department_scope!(attrs)
    return unless attrs.key?(:department_id)
    return if attrs[:department_id].blank?
    return if Department.exists?(id: attrs[:department_id], company_id: employee.company_id)

    errors.add(:proposed_changes, "contains a department outside the employee company")
    raise ActiveRecord::RecordInvalid, self
  end
end
