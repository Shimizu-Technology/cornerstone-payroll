# frozen_string_literal: true

# Keeps a successor company in comparison-only mode until its reviewed
# QuickBooks cutover has both technical and operations approval. Companies that
# were not created through the cutover workflow are unaffected.
class PayrollGoLiveGate
  class BlockedError < StandardError; end

  COMPARISON_ONLY_MESSAGE =
    "Live payroll is blocked until the payroll go-live review is approved. " \
    "Use a parallel comparison run while the cutover checklist is still open."

  def initialize(company:, pay_date:)
    @company = company
    @pay_date = pay_date
  end

  def state
    {
      required: applies?,
      approved: review&.approved? || false,
      comparison_only: comparison_only?,
      effective_on: review&.effective_on,
      review_status: review&.status,
      blockers: comparison_only? ? PayrollGoLiveReadiness.new(review).blockers : []
    }
  end

  def comparison_only?
    applies? && !review.approved?
  end

  def require_live_payroll!(parallel_run:)
    return unless comparison_only?
    return if parallel_run

    raise BlockedError, COMPARISON_ONLY_MESSAGE
  end

  private

  attr_reader :company, :pay_date

  def review
    @review ||= company.payroll_go_live_review
  end

  def applies?
    review.present? && normalized_pay_date >= review.effective_on
  end

  def normalized_pay_date
    @normalized_pay_date ||= pay_date.is_a?(Date) ? pay_date : Date.iso8601(pay_date.to_s)
  rescue Date::Error
    Date.current
  end
end
