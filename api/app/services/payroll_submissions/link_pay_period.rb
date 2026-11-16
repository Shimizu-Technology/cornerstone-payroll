# frozen_string_literal: true

module PayrollSubmissions
  # Automatic links may follow editable run dates/purpose. Retained source
  # selections remain authoritative; each run can belong to only one period.
  class LinkPayPeriod
    def self.candidates(period)
      taken = PayrollSubmissionPeriod.where.not(pay_period_id: nil).where.not(id: period.id).select(:pay_period_id)
      PayPeriod.portal_submission_runs.where(company_id: period.company_id,
        start_date: period.start_date, end_date: period.end_date).where.not(id: taken)
    end

    def self.retained_selection?(run)
      PayrollSubmissionImport.joins(:payroll_import).where(payroll_imports: { pay_period_id: run.id }).exists? ||
        PayrollIntakeDocument.joins(:payroll_intake_session)
          .where(payroll_intake_sessions: { pay_period_id: run.id }).where.not(payroll_submission_document_id: nil).exists?
    end

    def self.call(period)
      Company.find(period.company_id).with_lock do
        period.lock!
        return period if period.pay_period_id && period.pay_period.correction_status != "voided"

        matches = candidates(period).order(:id).limit(2).to_a
        period.update!(pay_period: matches.sole) if matches.one?
      end
      period
    end

    def self.for_run(run)
      return unless run.portal_submission_run?

      period = PayrollSubmissionPeriod.left_joins(:pay_period).where(company_id: run.company_id,
        start_date: run.start_date, end_date: run.end_date)
        .where("payroll_submission_periods.pay_period_id IS NULL OR pay_periods.correction_status = ?", "voided").first
      call(period) if period
    end

    # Called inside the run's transaction, before destructive child writes.
    def self.release_automatic!(run)
      period = PayrollSubmissionPeriod.find_by(pay_period_id: run.id)
      return unless period
      Company.lock.find(run.company_id)
      period.lock!
      return unless period.pay_period_id == run.id
      return if retained_selection?(run)

      period.update!(pay_period: nil)
      period
    end

    def self.refresh_for_run(run)
      released = release_automatic!(run)
      call(released) if released
      for_run(run)
    end

    # Commit is an explicit choice of this run. With requests outstanding,
    # ambiguous dates still need staff resolution before this point.
    def self.for_commit!(run)
      return unless run.portal_submission_run?
      return if PayrollSubmissionPeriod.exists?(pay_period_id: run.id)

      period = PayrollSubmissionPeriod.lock.find_by(company_id: run.company_id, pay_period_id: nil,
        start_date: run.start_date, end_date: run.end_date)
      return unless period

      matches = candidates(period)
      return unless matches.exists?(id: run.id)
      return if period.outstanding_file_requests.exists? && matches.count > 1

      period.update!(pay_period: run)
    end
  end
end
