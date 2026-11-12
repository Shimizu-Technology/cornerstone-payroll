# frozen_string_literal: true

# Immutable selection evidence. Two portal revisions can share identical Revel
# bytes and therefore an intake package, but never share an implicit checklist.
class PayrollSubmissionImport < ApplicationRecord
  belongs_to :payroll_submission
  belongs_to :payroll_import, class_name: "PayrollImportRecord"
  belongs_to :current_submission, class_name: "PayrollSubmission"
  belongs_to :selected_by, class_name: "User"

  validate :same_period_and_company
  validate :selection_immutable, on: :update
  validates :superseded_reason, presence: true, if: -> { payroll_submission_id != current_submission_id }
  validates :superseded_reason, length: { maximum: 2000 }, allow_nil: true

  def period
    payroll_submission.period
  end

  def validate_current!
    unless period.submissions.first&.id == current_submission_id
      raise ArgumentError, "A newer portal revision arrived. Reopen the submission in import review before applying."
    end
  end

  private

  def same_period_and_company
    source = payroll_submission
    current = current_submission
    run = payroll_import&.pay_period
    return if source && current && run && source.company_id == run.company_id &&
      source.payroll_submission_period_id == current.payroll_submission_period_id &&
      period.start_date == run.start_date && period.end_date == run.end_date && period.pay_period_id == run.id

    errors.add(:base, "Portal source and import must belong to the same company and period")
  end

  def selection_immutable
    errors.add(:base, "Portal source selection cannot change") if (changes_to_save.keys - %w[applied_at updated_at]).any?
  end
end
