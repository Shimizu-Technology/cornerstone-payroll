# frozen_string_literal: true

require "digest"

# One financial-year ledger for both live payroll and signed corrections.
# Unlike display YTD, this includes committed runs after a backdated paycheck.
# Callers that persist/approve money hold Company -> PayPeriod locks.
class EmployeeYearFicaContext
  class UnreconciledLedgerError < ArgumentError; end

  STALE_MESSAGE = "Recalculate — another payroll for this employee changed their year-to-date. If approved, select Roll Back Approval, then recalculate, review and approve again.".freeze
  MISSING_MESSAGE = "Recalculate — this payroll lacks annual context verification. If approved, select Roll Back Approval, then recalculate, review and approve again.".freeze
  UNLOADED = Object.new.freeze
  VERSION = 3
  LEDGER_FIELDS = %w[
    id pay_period_id gross_pay cash_tips_reported reported_tips medicare_taxable_wages
    social_security_taxable_wages social_security_taxable_tips social_security_tax
    employer_social_security_tax medicare_tax employer_medicare_tax additional_medicare_tax additional_medicare_taxable_wages
    withholding_tax additional_withholding retirement_payment roth_retirement_payment
    employer_retirement_match employer_roth_retirement_match net_pay
  ].freeze

  OPENING_FIELDS = %w[
    id employee_id historical_ytd_bridge_id tax_year through_pay_date through_period_end
    medicare_taxable_wages social_security_taxable_wages social_security_taxable_tips reported_tips
  ].freeze

  FINGERPRINT_FIELDS = (LEDGER_FIELDS + %w[correction_for_payroll_item_id]).freeze
  ROW_FIELDS = ((FINGERPRINT_FIELDS + %w[employee_id company_id]).map { |field| "payroll_items.#{field}" } + [
    Arel.sql("jsonb_strip_nulls(jsonb_build_object(#{(%w[tax_year] + FicaBasisEvidence::RULE_FIELDS).map { |field| "'#{field}', payroll_items.tax_rule_snapshot -> '#{field}'" }.join(', ')})) AS recorded_fica_rules"),
    Arel.sql("payroll_items.tax_rule_snapshot -> 'annual_fica_context' AS recorded_annual_fica_context"),
    Arel.sql("payroll_item_fica_basis_proofs.evidence AS recorded_legacy_fica_proof") ]).freeze

  def self.ledger_rows(scope)
    scope.left_joins(:fica_basis_proof).select(*ROW_FIELDS)
  end

  # Retired instruments retain earned payroll; only financial reversals remove
  # rows. Share the same inclusion policy as reports and corrective baselines.
  def self.reportable_items(employee: nil, company: nil, employee_ids: nil, year:, excluding_pay_period_id: nil)
    company ||= employee.company
    employee_ids ||= [ employee.id ]
    periods = PayPeriod.reportable_for_company(company).for_year(year)
    periods = periods.where.not(id: excluding_pay_period_id) if excluding_pay_period_id
    PayrollItem.financially_reportable.reportable.where(company_id: company.id, employee_id: employee_ids, pay_period_id: periods.select(:id))
      .where.not(employment_type: "contractor")
  end

  def self.opening_balances(employee_ids:, year:, company:)
    HistoricalEmployeeYtdBalance.joins(:historical_ytd_bridge)
      .where(employee_id: employee_ids, company_id: company.id, tax_year: year, historical_ytd_bridges: { status: "applied" })
      .select(*OPENING_FIELDS.map { |field| "historical_employee_ytd_balances.#{field}" })
      .order(employee_id: :asc, through_pay_date: :desc, "historical_ytd_bridges.applied_at" => :desc,
        "historical_ytd_bridges.id" => :desc, id: :desc)
  end

  # Call within the operation's existing Company -> PayPeriod financial lock.
  # Each employee's rows retain deterministic ID order, without large JSON blobs.
  def self.batch(company:, employees:, year:, excluding_pay_period_id: nil)
    employees = employees.uniq(&:id)
    return {} if employees.empty?

    ids = employees.map(&:id)
    rows = ledger_rows(reportable_items(company: company, employee_ids: ids, year: year,
      excluding_pay_period_id: excluding_pay_period_id))
      .order(:employee_id, :id).to_a.group_by(&:employee_id)
    balances = opening_balances(employee_ids: ids, year: year, company: company).to_a.group_by(&:employee_id)
    employees.to_h do |employee|
      [ employee.id, new(employee: employee, company: company, year: year, rows: rows.fetch(employee.id, []),
        opening_balance: balances[employee.id]&.first) ]
    end
  end

  def initialize(employee:, year:, excluding_pay_period_id: nil, company: nil, rows: nil, opening_balance: UNLOADED)
    @employee = employee
    @company = company || employee.company
    @year = year
    @excluding_pay_period_id = excluding_pay_period_id
    @rows = rows if rows
    @opening_balance = opening_balance unless opening_balance.equal?(UNLOADED)
  end

  def snapshot
    { "version" => VERSION, "year" => year, "employee_id" => employee.id, "fingerprint" => fingerprint }
  end

  def fingerprint
    @fingerprint ||= fingerprint_for(VERSION)
  end

  def fingerprint_for(version)
    Digest::SHA256.hexdigest(JSON.generate([
      version, year, employee.id, rows.map { |row| fingerprint_row(row, include_recovery: version >= 3) },
      opening_balance&.attributes&.slice(*OPENING_FIELDS)
    ]))
  end

  # Monetary amounts use decimal arithmetic and round half up at the stored
  # paycheck component boundary, matching the existing tax calculators.
  # Allocate wages before tips within this check, preserving committed buckets.
  def increment(wages_delta:, tips_delta:, rules:, correcting_bases: nil)
    delta = wages_delta.to_d.round(2)
    tips_delta = tips_delta.to_d.round(2)
    cap = rules.fetch("social_security_wage_base").to_d
    prior_ss = recorded_ss_bases(rules)
    validate_recorded_cap!(cap, prior_ss.fetch(:total))
    after = cumulative_wages + delta
    ss_total = capped(after, cap) - prior_ss.fetch(:total)
    ss_wages, ss_tips = split_ss_delta(ss_total, delta - tips_delta, tips_delta, correcting_bases)
    if correcting_bases
      actual_tips = rows.sum(0.to_d) { |row| (row.cash_tips_reported || row.reported_tips).to_d } + opening_balance&.reported_tips.to_d + tips_delta
      excess_tips = [ prior_ss.fetch(:tips) + ss_tips - actual_tips, 0.to_d ].max
      if excess_tips.positive?
        # A reviewed tip reduction may release taxed tips into later, already
        # earned non-tip wages. Prove both the target and annual wage capacity.
        annual_wages = after - actual_tips
        unless excess_tips <= [ -tips_delta, 0.to_d ].max && excess_tips <= correcting_bases.fetch(:tips).to_d &&
            prior_ss.fetch(:wages) + ss_wages + excess_tips <= annual_wages && actual_tips >= 0
          raise UnreconciledLedgerError, "Social Security tip allocation needs an explicit reviewed reconciliation."
        end
        ss_wages += excess_tips
        ss_tips -= excess_tips
      end
    end
    additional_base = excess(after, 200_000.to_d) - recorded_additional_base(rules)
    ss_tax = money(ss_total * rules.fetch("social_security_rate").to_d)
    base_medicare = money(delta * rules.fetch("medicare_rate").to_d)
    additional = money(additional_base * rules.fetch("additional_medicare_rate").to_d)
    {
      social_security_taxable_wages: money(ss_wages),
      social_security_taxable_tips: money(ss_tips),
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

  attr_reader :employee, :year, :excluding_pay_period_id, :company

  def rows
    @rows ||= self.class.ledger_rows(self.class.reportable_items(employee: employee, company: company, year: year,
      excluding_pay_period_id: excluding_pay_period_id)).order(:id).to_a
  end

  def opening_balance
    return @opening_balance if defined?(@opening_balance)

    @opening_balance = self.class.opening_balances(employee_ids: [ employee.id ], year: year, company: company).first
  end

  # Preserve each known signed base. A missing base is recoverable only
  # when its captured annual fingerprint proves the unchanged prior ledger,
  # replay agrees with every known component, and stored taxes corroborate it.
  # Rounded tax alone does not establish a partial wage or tip base.
  def recorded_ss_bases(rules)
    totals = { wages: opening_balance&.social_security_taxable_wages.to_d,
      tips: opening_balance&.social_security_taxable_tips.to_d }
    rows.each do |row|
      wages, tips = row.social_security_taxable_wages, row.social_security_taxable_tips
      if wages.nil? || tips.nil?
        recovered = recovered_bases(row, rules)
        supported = row.social_security_tax == recovered.fetch(:social_security_tax) &&
          row.employer_social_security_tax == recovered.fetch(:employer_social_security_tax) &&
          (wages.nil? || wages == recovered.fetch(:social_security_taxable_wages)) &&
          (tips.nil? || tips == recovered.fetch(:social_security_taxable_tips))
        hold_legacy!(row, "Social Security wage/tip") unless supported
        wages ||= recovered.fetch(:social_security_taxable_wages)
        tips ||= recovered.fetch(:social_security_taxable_tips)
      end
      totals[:wages] += wages
      totals[:tips] += tips
    end
    totals.merge(total: totals[:wages] + totals[:tips])
  end

  def recorded_additional_base(rules)
    rows.sum(0.to_d) do |row|
      next row.additional_medicare_taxable_wages if row.additional_medicare_taxable_wages.present?

      recovered = recovered_bases(row, rules)
      supported = row.additional_medicare_tax == recovered.fetch(:additional_medicare_tax) ||
        (row.additional_medicare_tax.nil? && row[:recorded_legacy_fica_proof].present?)
      hold_legacy!(row, "Additional Medicare") unless supported
      recovered.fetch(:additional_medicare_taxable_wages)
    end + excess(opening_balance&.medicare_taxable_wages.to_d, 200_000.to_d)
  end

  def recovered_bases(row, rules)
    @recovered_bases ||= {}
    @recovered_bases[row.id] ||= begin
      if row[:recorded_legacy_fica_proof].present?
        recovered = FicaBasisEvidence.verified_bases(row[:recorded_legacy_fica_proof], row: row,
          year: year, employee_id: employee.id)
        hold_legacy!(row, "reviewed legacy FICA") unless recovered
        return @recovered_bases[row.id] = recovered
      end
      # Signed corrections need their reviewed target's allocations; missing
      # correction bases cannot safely be replayed as an ordinary paycheck.
      hold_legacy!(row, "FICA") if row.correction_for_payroll_item_id.present? || row.gross_pay.negative?
      prior_rows = rows.take_while { |prior| prior.id < row.id }
      prior = self.class.new(employee: employee, company: company, year: year, rows: prior_rows, opening_balance: opening_balance)
      stored = row[:recorded_annual_fica_context]
      stored = {} unless stored.is_a?(Hash)
      proof = if [ 2, VERSION ].include?(stored["version"])
        prior.fingerprint_for(stored["version"])
      elsif !stored.key?("version") && opening_balance.nil?
        # v1 fingerprints included the complete opening row; only the
        # no-opening-balance form can be verified from this bounded projection.
        Digest::SHA256.hexdigest(JSON.generate([ year, employee.id, prior_rows.map { |item| item.attributes.slice(*LEDGER_FIELDS) }, nil ]))
      end
      unless proof && stored["year"] == year && stored["employee_id"] == employee.id && stored["fingerprint"] == proof
        hold_legacy!(row, "FICA")
      end
      prior.increment(wages_delta: row.medicare_taxable_wages || row.gross_pay,
        tips_delta: row.cash_tips_reported || row.reported_tips, rules: rules)
    end
  end

  def fingerprint_row(row, include_recovery: true)
    attributes = row.attributes.slice(*FINGERPRINT_FIELDS)
    if row.social_security_taxable_wages.nil? || row.social_security_taxable_tips.nil? || row.additional_medicare_taxable_wages.nil?
      attributes["legacy_basis_evidence"] = row[:recorded_annual_fica_context]
      attributes["captured_fica_rules"] = FicaBasisEvidence.rule_evidence(row) if include_recovery
      if include_recovery && row[:recorded_legacy_fica_proof].present?
        attributes["reviewed_legacy_basis_evidence"] = row[:recorded_legacy_fica_proof]
      end
    end
    attributes
  end

  def hold_legacy!(row, component)
    raise UnreconciledLedgerError,
      "Payroll item ##{row.id} lacks verified #{component} bases. Hold payroll for an explicit reviewed annual reconciliation."
  end

  def validate_recorded_cap!(cap, recorded)
    return if recorded <= cap

    raise UnreconciledLedgerError,
      "Annual Social Security history already exceeds the wage base. Hold payroll for a separately reviewed annual adjustment."
  end

  # Signed reclassifications belong to the reviewed target only. Ordinary
  # wage-only checks cannot move last quarter's taxed tips into wages.
  def split_ss_delta(total, wage_delta, tip_delta, correcting_bases)
    to_tips = 0.to_d
    to_wages = 0.to_d
    if correcting_bases
      to_tips = [ [ tip_delta, 0.to_d ].max, [ -wage_delta, 0.to_d ].max, [ correcting_bases.fetch(:wages).to_d, 0.to_d ].max ].min
      to_wages = [ [ wage_delta, 0.to_d ].max, [ -tip_delta, 0.to_d ].max, [ correcting_bases.fetch(:tips).to_d, 0.to_d ].max ].min
    end
    direction = total.negative? ? -1 : 1
    available_wages = [ wage_delta * direction - (direction.positive? ? to_wages : to_tips), 0.to_d ].max
    available_tips = [ tip_delta * direction - (direction.positive? ? to_tips : to_wages), 0.to_d ].max
    wages = [ total.abs, available_wages ].min
    tips = [ total.abs - wages, available_tips ].min
    unless wages + tips == total.abs
      raise UnreconciledLedgerError, "Annual Social Security bases need an explicit reviewed reconciliation beyond this check's wage/tip changes."
    end
    [ wages * direction + to_wages - to_tips, tips * direction + to_tips - to_wages ]
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
