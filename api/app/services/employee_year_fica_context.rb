# frozen_string_literal: true

require "digest"

# One financial-year ledger for both live payroll and signed corrections.
# Unlike display YTD, this includes committed runs after a backdated paycheck.
# Callers that persist/approve money hold Company -> PayPeriod locks.
class EmployeeYearFicaContext
  class UnreconciledLedgerError < ArgumentError; end

  STALE_MESSAGE = "Recalculate — another payroll for this employee changed their year-to-date".freeze
  LEDGER_FIELDS = %w[
    id pay_period_id gross_pay cash_tips_reported reported_tips medicare_taxable_wages
    social_security_taxable_wages social_security_taxable_tips social_security_tax
    employer_social_security_tax medicare_tax employer_medicare_tax additional_medicare_tax additional_medicare_taxable_wages
    withholding_tax additional_withholding retirement_payment roth_retirement_payment
    employer_retirement_match employer_roth_retirement_match net_pay
  ].freeze

  # Keep reportability in one place so instrument-void policy changes also
  # reach calculation, corrective previews, and stale-context validation.
  def self.reportable_items(employee:, year:, excluding_pay_period_id: nil)
    periods = PayPeriod.reportable_for_company(employee.company).for_year(year)
    periods = periods.where.not(id: excluding_pay_period_id) if excluding_pay_period_id
    employee.payroll_items.not_voided.where(pay_period_id: periods.select(:id))
      .where.not(employment_type: "contractor")
  end

  def initialize(employee:, year:, excluding_pay_period_id: nil)
    @employee = employee
    @year = year
    @excluding_pay_period_id = excluding_pay_period_id
  end

  def snapshot
    { "year" => year, "employee_id" => employee.id, "fingerprint" => fingerprint }
  end

  def fingerprint
    @fingerprint ||= Digest::SHA256.hexdigest(JSON.generate([
      year, employee.id, rows.map { |row| row.attributes.slice(*LEDGER_FIELDS) },
      opening_balance&.attributes
    ]))
  end

  # Monetary amounts use decimal arithmetic and round half up at the stored
  # paycheck component boundary, matching the existing tax calculators.
  # Wages take priority over tips within the shared Social Security cap.
  def increment(wages_delta:, tips_delta:, rules:)
    delta = wages_delta.to_d.round(2)
    tips_delta = tips_delta.to_d.round(2)
    cap = rules.fetch("social_security_wage_base").to_d
    validate_recorded_cap!(cap)
    before = cumulative_wages
    after = before + delta
    prior_ss = recorded_ss_bases(cap)
    ss_total = capped(after, cap) - prior_ss.fetch(:total)
    ss_wages = capped(after - cumulative_tips - tips_delta, cap) - prior_ss.fetch(:wages)
    additional_base = excess(after, 200_000.to_d) - recorded_additional_base
    ss_tax = money(ss_total * rules.fetch("social_security_rate").to_d)
    base_medicare = money(delta * rules.fetch("medicare_rate").to_d)
    additional = money(additional_base * rules.fetch("additional_medicare_rate").to_d)
    {
      social_security_taxable_wages: money(ss_wages),
      social_security_taxable_tips: money(ss_total - ss_wages),
      medicare_taxable_wages: delta,
      additional_medicare_taxable_wages: money(additional_base),
      social_security_tax: ss_tax, employer_social_security_tax: ss_tax,
      medicare_tax: base_medicare + additional, employer_medicare_tax: base_medicare,
      additional_medicare_tax: additional
    }
  end

  def cumulative_wages
    # Medicare wages are uncapped FICA-eligible gross in this application's
    # tax contract. Never reconstruct uncapped wages from capped SS amounts.
    @cumulative_wages ||= rows.sum(0.to_d) { |row| (row.medicare_taxable_wages || row.gross_pay).to_d } +
      opening_balance&.medicare_taxable_wages.to_d
  end

  private

  attr_reader :employee, :year, :excluding_pay_period_id

  def rows
    @rows ||= self.class.reportable_items(employee: employee, year: year,
      excluding_pay_period_id: excluding_pay_period_id).order(:id).to_a
  end

  def opening_balance
    return @opening_balance if defined?(@opening_balance)

    @opening_balance = employee.historical_employee_ytd_balances.joins(:historical_ytd_bridge)
      .where(tax_year: year, historical_ytd_bridges: { status: "applied" })
      .order(through_pay_date: :desc, "historical_ytd_bridges.applied_at" => :desc,
        "historical_ytd_bridges.id" => :desc, id: :desc).first
  end

  # Voiding one signed adjustment can leave a later adjustment's capped
  # bases behind. Reconcile that remaining balance in the next reviewed
  # calculation, rather than treating a capped base as uncapped earnings.
  def recorded_ss_bases(cap)
    if rows.any? { |row| row.social_security_taxable_wages.nil? || row.social_security_taxable_tips.nil? }
      return { total: capped(cumulative_wages, cap), wages: capped(cumulative_wages - cumulative_tips, cap) }
    end

    wages = rows.sum(0.to_d) { |row| row.social_security_taxable_wages.to_d } + opening_balance&.social_security_taxable_wages.to_d
    tips = rows.sum(0.to_d) { |row| row.social_security_taxable_tips.to_d } + opening_balance&.social_security_taxable_tips.to_d
    { total: wages + tips, wages: wages }
  end

  def recorded_additional_base
    return excess(cumulative_wages, 200_000.to_d) if rows.any? { |row| row.additional_medicare_taxable_wages.nil? }

    rows.sum(0.to_d) { |row| row.additional_medicare_taxable_wages.to_d } +
      excess(opening_balance&.medicare_taxable_wages.to_d, 200_000.to_d)
  end

  def validate_recorded_cap!(cap)
    return if rows.any? { |row| row.social_security_taxable_wages.nil? || row.social_security_taxable_tips.nil? }

    recorded = rows.sum(0.to_d) { |row| row.social_security_taxable_wages + row.social_security_taxable_tips }
    recorded += opening_balance.social_security_taxable_wages + opening_balance.social_security_taxable_tips if opening_balance
    return if recorded <= cap

    raise UnreconciledLedgerError,
      "Annual Social Security history already exceeds the wage base. Hold payroll for a separately reviewed annual adjustment."
  end

  def cumulative_tips
    rows.sum(0.to_d) { |row| (row.cash_tips_reported || row.reported_tips).to_d } + opening_balance&.reported_tips.to_d
  end

  def capped(value, cap)
    [ [ value, 0.to_d ].max, cap ].min
  end

  def excess(value, threshold)
    [ value - threshold, 0.to_d ].max
  end

  def money(value)
    value.round(2, BigDecimal::ROUND_HALF_UP)
  end
end
