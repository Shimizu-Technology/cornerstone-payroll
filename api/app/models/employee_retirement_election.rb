# frozen_string_literal: true

class EmployeeRetirementElection < ApplicationRecord
  CONTRIBUTION_TYPES = %w[percentage fixed].freeze
  ELIGIBLE_COMPENSATION_OPTIONS = %w[gross_wages gross_excluding_tips base_pay].freeze
  LIMIT_PRIORITIES = %w[proportional traditional_first roth_first].freeze
  MATCH_MODES = %w[none compensation_percentage employee_deferral_percentage].freeze
  MATCH_DESTINATIONS = %w[traditional roth].freeze
  TRUE_UP_POLICIES = %w[none year_to_date].freeze
  SOURCES = %w[staff employee_creation quickbooks_history].freeze

  SNAPSHOT_ATTRIBUTES = %i[
    plan_name eligible participating traditional_contribution_type traditional_rate traditional_amount
    roth_contribution_type roth_rate roth_amount eligible_compensation catch_up_enabled limit_priority
    plan_annual_employee_limit employer_match_mode employer_match_rate employer_match_deferral_cap_rate
    employer_match_period_cap employer_match_annual_cap employer_match_ytd_before_system
    employer_match_destination true_up_policy
  ].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :created_by, class_name: "User", optional: true

  validates :effective_on, :plan_name, :source, :reason, presence: true
  validates :effective_on, uniqueness: { scope: :employee_id }
  validates :traditional_contribution_type, :roth_contribution_type, inclusion: { in: CONTRIBUTION_TYPES }
  validates :eligible_compensation, inclusion: { in: ELIGIBLE_COMPENSATION_OPTIONS }
  validates :limit_priority, inclusion: { in: LIMIT_PRIORITIES }
  validates :employer_match_mode, inclusion: { in: MATCH_MODES }
  validates :employer_match_destination, inclusion: { in: MATCH_DESTINATIONS }
  validates :true_up_policy, inclusion: { in: TRUE_UP_POLICIES }
  validates :source, inclusion: { in: SOURCES }
  validates :traditional_rate, :roth_rate, :employer_match_rate,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :employer_match_deferral_cap_rate,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }, allow_nil: true
  validates :traditional_amount, :roth_amount, :plan_annual_employee_limit,
    :employer_match_period_cap, :employer_match_annual_cap, :employer_match_ytd_before_system,
    numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validate :company_matches_employee
  validate :creator_belongs_to_company_organization
  validate :participation_requires_eligibility
  validate :configured_contributions_match_type
  validate :true_up_has_supported_compensation_history

  before_update :prevent_mutation
  before_destroy :prevent_mutation

  scope :recent_first, -> { order(effective_on: :desc, created_at: :desc, id: :desc) }
  scope :effective_on, ->(date) { where("effective_on <= ?", date).recent_first }

  def snapshot_attributes
    SNAPSHOT_ATTRIBUTES.index_with { |attribute| public_send(attribute) }
      .merge(election_id: id, effective_on: effective_on, source: source)
  end

  private

  def prevent_mutation
    errors.add(:base, "Retirement election history is append-only")
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

  def participation_requires_eligibility
    errors.add(:participating, "cannot be enabled for an ineligible employee") if participating? && !eligible?
  end

  def configured_contributions_match_type
    if traditional_contribution_type == "fixed" && traditional_rate.to_d.positive?
      errors.add(:traditional_rate, "must be zero when a fixed amount is used")
    end
    if roth_contribution_type == "fixed" && roth_rate.to_d.positive?
      errors.add(:roth_rate, "must be zero when a fixed amount is used")
    end
  end

  def true_up_has_supported_compensation_history
    return unless true_up_policy == "year_to_date" && employer_match_mode == "compensation_percentage"
    return if eligible_compensation == "gross_wages"

    errors.add(:true_up_policy, "can only reconcile a compensation-based match when all gross wages are eligible")
  end
end
