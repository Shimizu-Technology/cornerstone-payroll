# frozen_string_literal: true

class EmployeeW4Election < ApplicationRecord
  PROFILE_ATTRIBUTES = %i[
    filing_status
    allowances
    additional_withholding
    w4_dependent_credit
    w4_step2_multiple_jobs
    w4_step4a_other_income
    w4_step4b_deductions
    w4_form_version
    w4_signed_on
    w4_source_reference
    w4_effective_on
  ].freeze
  SNAPSHOT_ATTRIBUTES = PROFILE_ATTRIBUTES - [ :w4_effective_on ]
  SOURCES = %w[staff client_approved employee_creation legacy_profile quickbooks_history].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :created_by, class_name: "User", optional: true

  validates :effective_on, presence: true
  validates :filing_status, inclusion: { in: %w[single married married_separate head_of_household] }
  validates :allowances, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :additional_withholding, :w4_dependent_credit, :w4_step4a_other_income, :w4_step4b_deductions,
    numericality: { greater_than_or_equal_to: 0 }
  validates :w4_source_reference, length: { maximum: 255 }, allow_nil: true
  validates :w4_form_version,
    numericality: { only_integer: true, greater_than_or_equal_to: 1987, less_than_or_equal_to: ->(_) { Date.current.year + 1 } }
  validates :source, inclusion: { in: SOURCES }
  validates :reason, presence: true
  validate :company_matches_employee
  validate :creator_belongs_to_company_organization

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :chronological, -> { order(effective_on: :asc, created_at: :asc, id: :asc) }
  scope :recent_first, -> { order(effective_on: :desc, created_at: :desc, id: :desc) }
  scope :effective_on, ->(date) { where("effective_on <= ?", date).recent_first }

  def profile_attributes
    SNAPSHOT_ATTRIBUTES.index_with { |attribute| public_send(attribute) }
      .merge(w4_effective_on: effective_on)
  end

  private

  def prevent_mutation
    errors.add(:base, "W-4 election history is append-only")
    throw :abort
  end

  def company_matches_employee
    return if company.blank? || employee.blank? || company_id == employee.company_id

    errors.add(:company, "must match the employee company")
  end

  def creator_belongs_to_company_organization
    return if created_by.blank? || company.blank?
    return if created_by.organization_id == company.organization_id

    errors.add(:created_by, "must belong to the same organization")
  end
end
