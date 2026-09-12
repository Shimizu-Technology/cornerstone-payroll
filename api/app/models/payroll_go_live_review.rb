# frozen_string_literal: true

class PayrollGoLiveReview < ApplicationRecord
  STATUSES = %w[draft setup_applied approved].freeze
  ATTESTATIONS = {
    "employee_setup" => "Every active employee profile and typed recurring payroll field was reviewed; no free-text legacy recurring item remains.",
    "w4_history" => "W-4 effective dates and current elections were reviewed for every W-2 employee.",
    "loan_balances" => "Every recurring loan deduction has a verified opening balance or a documented resolution.",
    "pay_schedule" => "The pay schedule and legal overtime workweek were confirmed with the employer.",
    "check_settings" => "Check stock, alignment, next check number, and payment workflow were tested.",
    "historical_reports" => "Imported history and annual totals were reconciled to retained QuickBooks evidence.",
    "rollback_plan" => "QuickBooks remains available and an owner is assigned if the first live payroll must be stopped."
  }.freeze
  TECHNICAL_ACKNOWLEDGEMENT = "TECHNICAL GO-LIVE CHECKS COMPLETE"
  OPERATIONS_ACKNOWLEDGEMENT = "OPERATIONS GO-LIVE CHECKS COMPLETE"

  belongs_to :company
  belongs_to :source_company, class_name: "Company"
  belongs_to :historical_import_batch
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :setup_applied_by, class_name: "User", optional: true
  belongs_to :technical_signed_by, class_name: "User", optional: true
  belongs_to :operations_signed_by, class_name: "User", optional: true
  belongs_to :company_setup_reviewed_by, class_name: "User", optional: true
  has_many :payroll_parallel_run_reviews, dependent: :restrict_with_error

  validates :company_id, uniqueness: true
  validates :historical_import_batch_id, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :plan_digest, presence: true
  validates :effective_on, presence: true
  validates :review_notes, length: { maximum: 2_000 }, allow_blank: true
  validates :company_setup_review_notes, length: { maximum: 2_000 }, allow_blank: true
  validates :company_setup_reviewed_by_name, :company_setup_reviewed_by_email,
            :company_setup_reviewed_by_role, presence: true, if: :company_setup_digest?
  validate :companies_share_organization
  validate :batch_matches_destination
  validate :different_companies

  before_update :prevent_approved_update
  before_destroy :prevent_destroy

  def setup_applied?
    status.in?(%w[setup_applied approved])
  end

  def approved?
    status == "approved"
  end

  def attestations_complete?
    ATTESTATIONS.keys.all? { |key| ActiveModel::Type::Boolean.new.cast(attestations.to_h[key]) }
  end

  def consecutive_pass_count
    payroll_parallel_run_reviews.joins(:pay_period)
      .order("pay_periods.pay_date DESC, payroll_parallel_run_reviews.id DESC")
      .limit(2).to_a.take_while(&:pass?).size
  end

  def ready_for_signoff?
    setup_applied? && Array(validation_errors).empty? && attestations_complete? &&
      consecutive_pass_count >= 2 && runtime_blockers.empty? && review_notes.to_s.strip.present?
  end

  def runtime_blockers
    PayrollGoLiveReadiness.new(self).blockers
  end

  private

  def companies_share_organization
    return if company.blank? || source_company.blank? || company.organization_id == source_company.organization_id

    errors.add(:source_company, "must belong to the same organization")
  end

  def batch_matches_destination
    return if historical_import_batch.blank? || historical_import_batch.company_id == company_id

    errors.add(:historical_import_batch, "must belong to the successor company")
  end

  def different_companies
    errors.add(:source_company, "must be different from the successor company") if source_company_id == company_id
  end

  def prevent_approved_update
    return unless status_was == "approved"

    errors.add(:base, "Approved go-live evidence cannot be changed")
    throw(:abort)
  end

  def prevent_destroy
    errors.add(:base, "Go-live evidence cannot be deleted")
    throw(:abort)
  end
end
