# frozen_string_literal: true

module PayrollSubmissions
  # Persist only an unambiguous regular run. Existing links are authoritative,
  # including after date edits and creation of another same-date run. A newly
  # created unique replacement may explicitly claim a voided run's period.
  class LinkPayPeriod
    def self.call(period)
      Company.find(period.company_id).with_lock do
        period.lock!
        return period if period.pay_period_id && period.pay_period.correction_status != "voided"

        candidates = PayPeriod.portal_submission_runs.where(company_id: period.company_id,
          start_date: period.start_date, end_date: period.end_date).order(:id).limit(2).to_a
        period.update!(pay_period: candidates.sole) if candidates.one?
      end
      period
    end

    def self.for_run(run)
      return unless PayPeriod.portal_submission_runs.exists?(id: run.id)

      period = PayrollSubmissionPeriod.left_joins(:pay_period).where(company_id: run.company_id,
        start_date: run.start_date, end_date: run.end_date)
        .where("payroll_submission_periods.pay_period_id IS NULL OR pay_periods.correction_status = ?", "voided").first
      call(period) if period
    end
  end
end
