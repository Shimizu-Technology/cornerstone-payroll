# frozen_string_literal: true

# A paycheck's saved YTD gross as its pay stub prints it. The saved snapshot
# counts the applied opening balance's non-taxable reimbursements, which the
# stub shows as other pay (PayrollEarningsYtdBreakdown#pay_ytd_total). The
# snapshot itself is never rewritten. One instance caches each client-year's
# balances, so a pay run reads them once.
class StatementYtdGross
  def initialize
    @balances = {}
  end

  def call(item)
    return item.ytd_gross if item.ytd_gross.nil?

    year = item.pay_period.pay_date.year
    balance = (@balances[[ item.company_id, year ]] ||=
      HistoricalEmployeeYtdBalance.applied_by_employee(company_id: item.company_id, tax_year: year))[item.employee_id]
    balance ? (item.ytd_gross.to_d - balance.non_taxable_pay.to_d).round(2) : item.ytd_gross
  end
end
