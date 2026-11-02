# frozen_string_literal: true

module PriorProviderHistory
  # A suggestion, not an assertion that an unfinished run was already paid.
  # Conversion still checks every source and requires paid register evidence.
  class Discovery
    def self.candidates(company)
      company.pay_periods.calculated.where(committed_at: nil, cycle: "regular", run_purpose: "regular",
        parallel_run: false, correction_status: nil, corrects_pay_period_id: nil)
        .where("pay_date < ?", Date.current)
    end

    def self.available?(company, period: nil)
      return false if period && (!period.calculated? || period.committed_at.present? || period.pay_date >= Date.current ||
        !period.regular_cycle? || period.run_purpose != "regular" || period.parallel_run? ||
        period.correction_status.present? || period.corrects_pay_period_id.present?)
      return false if company.test_workspace?
      return false if company.pay_periods.where("status = 'committed' OR committed_at IS NOT NULL").exists?

      scope = candidates(company)
      scope = scope.where(id: period.id) if period
      scope.exists?
    end
  end
end
