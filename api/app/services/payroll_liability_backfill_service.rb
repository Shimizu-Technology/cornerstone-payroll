# frozen_string_literal: true

# Explicit operator-controlled backfill for payroll committed before the
# liability ledger existed. Preview is the default; execution requires the
# caller to pass confirm: true. Payroll calculations and payroll items are
# never changed.
class PayrollLiabilityBackfillService
  class ConfirmationRequiredError < StandardError; end

  def initialize(company:, through_date: Date.current, actor: nil)
    @company = company
    @through_date = through_date
    @actor = actor
  end

  def preview
    periods = eligible_periods
    {
      company_id: company.id,
      company_name: company.name,
      through_date: through_date,
      eligible_pay_period_ids: periods.pluck(:id),
      eligible_count: periods.count,
      already_posted_count: already_posted_count,
      payroll_item_count: PayrollItem.where(pay_period_id: periods.select(:id)).count
    }
  end

  def call(confirm: false)
    raise ConfirmationRequiredError, "Pass confirm: true after reviewing the preview" unless confirm

    posted_ids = []
    errors = []

    eligible_periods.find_each do |period|
      PayrollLiabilityPostingService.post!(
        pay_period: period,
        actor: actor,
        posting_type: "historical_backfill",
        idempotency_key: "pay-period:#{period.id}:historical-backfill",
        reason: "Explicit Phase 1 payroll-liability backfill",
        metadata: { "backfilled_at" => Time.current.iso8601 }
      )
      posted_ids << period.id
    rescue StandardError => e
      errors << { pay_period_id: period.id, error: "#{e.class}: #{e.message}" }
    end

    {
      company_id: company.id,
      posted_pay_period_ids: posted_ids,
      posted_count: posted_ids.size,
      errors: errors
    }
  end

  private

  attr_reader :company, :through_date, :actor

  def eligible_periods
    @eligible_periods ||= company.pay_periods
      .reportable_committed
      .where(pay_date: ..through_date)
      .where.not(id: PayrollLiabilityPosting.select(:pay_period_id))
      .period_chronological
  end

  def already_posted_count
    company.pay_periods.reportable_committed
      .where(pay_date: ..through_date)
      .where(id: PayrollLiabilityPosting.select(:pay_period_id))
      .count
  end
end
