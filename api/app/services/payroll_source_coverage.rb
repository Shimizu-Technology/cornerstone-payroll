# frozen_string_literal: true

# Matches the worksheet policy: a scheduled regular run needs an explicit
# decision until a finalized source batch has actually been added to payroll.
class PayrollSourceCoverage
  def self.acknowledgement_required?(pay_period)
    return false unless pay_period.run_purpose == "regular"

    summary = PayPeriodTimeTrackingSummary.call(pay_period)
    calendar = summary[:aire_calendar]
    calendar.present? && calendar[:enabled] &&
      (calendar[:cutoff_at].present? || calendar[:publication].present? || calendar[:external_pay_period_id].present?) &&
      summary[:linked_aire_records].empty?
  end
end
