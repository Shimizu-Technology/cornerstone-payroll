# frozen_string_literal: true

# Historical replay determines the requested target. This independent annual
# ledger proves that its remaining signed contribution fits today's committed
# year, including later payroll. It never caps or rewrites another paycheck.
class CorrectiveRetirementContext
  MESSAGE = "This correction requires a reviewed annual retirement reconciliation with the plan administrator; another committed paycheck or annual plan limit would need to change. Review the contribution ledger before issuing a supplemental paycheck."

  def initialize(employee:, original:, active:, pay_date: nil)
    @employee = Employee.find(employee.id)
    @original = original
    @active = active
    @year = original.pay_period.pay_date.year
    @pay_date = (pay_date || original.pay_period.pay_date).to_date
  end

  def snapshot
    {
      year: year, employee_id: employee.id, date_of_birth: employee.date_of_birth,
      governing_elections: plan_elections,
      annual_limit: annual_limit&.attributes, year_input: year_input,
      elections: employee.employee_retirement_elections.order(:id).map(&:snapshot_attributes),
      historical: projection.source, opening: opening,
      ledger: rows.map do |item|
        { id: item.id, period_id: item.pay_period_id, pay_date: item.pay_period.pay_date,
          totals: amounts(item), catch_up_classification: proved_catch_up(item), retirement_rule_snapshot: item.retirement_rule_snapshot }
      end
    }
  end

  def validate!(target)
    delta = amounts(target)
    recorded = [ original, *active ].map { |item| amounts(item) }
    delta.each_key { |key| delta[key] -= recorded.sum(0.to_d) { |values| values.fetch(key) } }
    totals = opening.dup
    rows.each { |item| amounts(item).each { |key, value| totals[key] += value } }
    delta.each { |key, value| totals[key] += value }
    return if totals.except(:gross, :match).values.all?(&:zero?) && delta.except(:gross, :match).values.all?(&:zero?)

    hold! unless annual_limit && annual_limit.elective_deferral_limit.to_d.positive? && annual_limit.annual_additions_limit.to_d.positive?
    hold! if totals.values.any?(&:negative?)
    evidence = original.retirement_rule_snapshot.to_h
    base = annual_limit.elective_deferral_limit.to_d
    governing_regular = plan_elections.first.to_h["regular_plan_deferral_limit"].presence
    regular = [ governing_regular ? governing_regular.to_d : base, base ].min
    # Catch-up classifications on correction snapshots are absolute targets,
    # not additive deltas. Only retain proved permission; ambiguous new annual
    # classifications require administrator review rather than inferred room.
    catch_up = 0.to_d
    if evidence["catch_up_permission_status"] == "permitted" &&
        canonical_year_input(evidence["year_input"].to_h) == canonical_year_input(year_input) &&
        employee.date_of_birth && year - employee.date_of_birth.year == evidence["employee_age_at_year_end"].to_i
      statutory = (year - employee.date_of_birth.year).between?(60, 63) ? annual_limit.enhanced_catch_up_limit : annual_limit.catch_up_limit
      catch_up = [ evidence["catch_up_limit"].to_d, statutory.to_d ].min
    end
    elective = totals[:retirement] + totals[:roth_retirement]
    external = year_input.fetch(:external_traditional_deferrals, 0).to_d + year_input.fetch(:external_roth_deferrals, 0).to_d
    hold! if elective + external > base + catch_up || elective > regular + catch_up
    plan_elections.each do |election|
      regular_cap = election["regular_plan_deferral_limit"].presence
      hold! if regular_cap && elective > regular_cap.to_d + catch_up
      cap = election["plan_annual_employee_limit"].presence
      hold! if cap && elective > cap.to_d
      match_cap = election["employer_match_annual_cap"].presence
      hold! if match_cap && totals[:match] > match_cap.to_d
    end
    additions = elective + totals[:employer] + totals[:non_roth_after_tax]
    additions_limit = [ annual_limit.annual_additions_limit.to_d, totals[:gross] ].min
    personal_local_catch_up = [ elective + external - base, 0.to_d ].max - [ external - base, 0.to_d ].max
    required = [ personal_local_catch_up, elective - regular, additions - additions_limit, 0.to_d ].max
    proved = rows.sum(0.to_d) { |item| proved_catch_up(item) } + catch_up_delta(target)
    hold! if proved.negative? || proved > catch_up || proved > elective || required > proved
    if proved.positive? && (year_input.fetch(:external_traditional_deferrals, 0).to_d.positive? ||
        (year >= 2026 && year_input.fetch(:prior_year_fica_wages, 0).to_d > annual_limit.roth_catch_up_wage_threshold.to_d && totals[:roth_retirement] < proved))
      hold!
    end
    hold! if totals[:gross] > annual_limit.compensation_limit.to_d && delta[:employer].positive?
    hold! if additions - proved > additions_limit

  rescue ArgumentError => e
    raise IssueCorrectivePaycheckService::MissingHistoricalContextError, "#{MESSAGE} #{e.message}"
  end

  def catch_up_delta(target)
    proved_catch_up(target) - [ original, *active ].sum(0.to_d) { |item| proved_catch_up(item) }
  end

  private

  def proved_catch_up(item)
    PayrollRetirementCatchUp.for_item(item)
  rescue PayrollRetirementCatchUp::UnprovedHistoryError => e
    raise IssueCorrectivePaycheckService::MissingHistoricalContextError, "#{MESSAGE} #{e.message}"
  end

  def canonical_year_input(value)
    value.stringify_keys.except("year_input_id").to_h do |key, entry|
      type = EmployeeRetirementYearInput.attribute_types[key]
      [ key, canonical_evidence(type ? type.cast(entry) : entry) ]
    end
  end

  def canonical_evidence(value)
    case value
    when BigDecimal then value.to_s("F")
    when Date, Time then value.iso8601
    when Hash then value.stringify_keys.transform_values { |entry| canonical_evidence(entry) }
    when Array then value.map { |entry| canonical_evidence(entry) }
    else value
    end
  end

  attr_reader :employee, :original, :active, :year

  def hold!
    raise IssueCorrectivePaycheckService::MissingHistoricalContextError, MESSAGE
  end

  def rows
    @rows ||= EmployeeYearFicaContext.reportable_items(employee: employee, year: year)
      .includes(:pay_period, :payroll_item_field_entries, payroll_item_deductions: :deduction_type).order(:id).to_a
  end

  def amounts(item)
    PayrollRetirementTotals.for_item(item).merge(PayrollRetirementTotals.additions_for_item(item)).merge(
      gross: item.gross_pay.to_d, match: item.employer_retirement_match.to_d + item.employer_roth_retirement_match.to_d
    )
  end

  def annual_limit
    @annual_limit ||= AnnualRetirementLimit.find_by(tax_year: year)
  end

  def year_input
    @year_input ||= employee.employee_retirement_year_inputs.where(tax_year: year).recent_first.first&.snapshot_attributes&.symbolize_keys || {}
  end

  def projection
    @projection ||= HistoricalRetirementProjection.new(employee: employee, tax_year: year, review: year_input.fetch(:historical_retirement_review, {}))
  end

  def opening
    @opening ||= begin
      imported = projection.totals(strict: true)
      # Opening match can be verified by a later effective election. It is an
      # alternative statement of imported match, never another additive row.
      match = (saved_elections + plan_elections).map do |election|
        election["effective_on"].presence&.to_date&.year == year ? election["employer_match_ytd_before_system"].to_d : 0.to_d
      end.max || 0.to_d
      {
        retirement: imported[:retirement], roth_retirement: imported[:roth_retirement],
        employer: [ projection.employer_additions, match ].max + year_input.fetch(:employer_additions_before_system, 0).to_d,
        non_roth_after_tax: imported[:non_roth_after_tax] + year_input.fetch(:non_roth_after_tax_before_system, 0).to_d,
        gross: employee.ytd_totals_for_scope(rows_scope, tax_year: year)[:gross_pay].to_d - rows.sum(0.to_d) { |item| item.gross_pay.to_d } + year_input.fetch(:eligible_compensation_before_system, 0).to_d,
        match: match
      }
    end
  end

  def plan_elections
    @plan_elections ||= begin
      through = [ @pay_date, *rows.map { |item| item.pay_period.pay_date } ].max
      current = employee.employee_retirement_elections.effective_on(through).first
      if current
        [ current.snapshot_attributes.stringify_keys ]
      else
        # Retained legacy snapshots may be the only available election proof.
        # Apply the latest governing snapshot, rather than every superseded cap.
        latest = saved_elections.select { |election| election["effective_on"].blank? || election["effective_on"].to_date <= through }
          .max_by { |election| election["effective_on"].presence&.to_date || Date.new(1, 1, 1) }
        latest ? [ latest ] : []
      end
    end
  end

  def saved_elections
    @saved_elections ||= [ original, *rows ].map do |item|
      evidence = item.retirement_rule_snapshot.to_h
      election = evidence.fetch("election", {}).deep_dup
      if evidence.fetch("version", 1).to_i < 2
        %w[regular_plan_deferral_limit plan_annual_employee_limit employer_match_annual_cap].each do |key|
          election.delete(key) if election[key].present? && election[key].to_d.zero?
        end
      end
      election
    end
  end

  def rows_scope
    EmployeeYearFicaContext.reportable_items(employee: employee, year: year)
  end
end
