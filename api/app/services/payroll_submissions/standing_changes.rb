# frozen_string_literal: true

module PayrollSubmissions
  class StandingChanges
    # rates_on: the submission period's end date; wage-rate labels and amounts
    # are shown as they stand on it (M3-4).
    def initialize(company:, before_pay_date:, rates_on: nil)
      @company = company
      @before_pay_date = before_pay_date
      @rates_on = rates_on || PayrollBusinessClock.today
    end

    def rows
      PayrollStandingChange.active.ordered.where(company: @company)
        .preload(:employee_wage_rate, employee: %i[employee_wage_rates employee_wage_rate_versions employee_compensation_changes]).map do |item|
        wage_rate = item.wage_rate_on(@rates_on)
        { standing_change_id: item.id, kind: item.kind, employee_id: item.employee_id, employee_name: item.employee.full_name,
          employee_wage_rate_id: item.employee_wage_rate_id, wage_rate_label: wage_rate&.label,
          wage_rate: wage_rate&.rate&.to_s("F"), position: item.position,
          label: item.display_label, help_text: item.help_text, required: item.required?, allow_none: item.allow_none?,
          availability_error: item.availability_error(rates_on: @rates_on), last_period_amount: previous_amount(item) }.compact
      end
    end

    private

    def previous_amount(item)
      return unless item.kind == "owner_pay" && @before_pay_date

      history = PayPeriod.committed
      if @company.test_workspace?
        history = history.or(PayPeriod.where(status: "approved", test_workspace_role: "baseline").where.not(test_workspace_source_pay_period_id: nil))
      end
      previous = item.employee.payroll_items.financially_reportable.joins(:pay_period).merge(history)
        .where(company_id: @company.id).where("pay_periods.pay_date < ?", @before_pay_date)
        .order("pay_periods.pay_date DESC, payroll_items.id DESC").first
      format("%.2f", previous.salary_override) if previous&.salary_override&.positive?
    end
  end
end
