# frozen_string_literal: true

# Applies one effective-dated employee retirement election across the built-in
# percentage/fixed fields and the flexible payroll-field/deduction paths. The
# result is capped as one combined employee elective deferral and preserved on
# the paycheck so an operator can explain every exclusion and cap later.
class PayrollRetirementCalculation
  Result = Data.define(:deduction_amounts, :snapshot)

  def initialize(employee:, payroll_item:, ytd_before:, employee_deductions:, historical_election: nil,
                 historical_limit: nil, historical_mode: false, recurring_items_enabled: true)
    @employee = employee
    @payroll_item = payroll_item
    @ytd_before = ytd_before
    @employee_deductions = employee_deductions
    @historical_election = historical_election&.deep_symbolize_keys
    @historical_limit = historical_limit&.deep_symbolize_keys
    @historical_mode = historical_mode
    @recurring_items_enabled = recurring_items_enabled
  end

  def apply!
    validate_annual_limit!
    sources = contribution_sources
    requested = totals_for(sources, :requested)
    allowed = allocate(requested)
    apply_source_caps!(sources, allowed)
    applied = totals_for(sources, :applied)
    apply_employer_match!(applied)

    snapshot = build_snapshot(requested:, applied:, sources:)
    payroll_item.retirement_rule_snapshot = snapshot
    Result.new(deduction_amounts: @deduction_amounts || {}, snapshot: snapshot)
  end

  private

  attr_reader :employee, :payroll_item, :ytd_before, :employee_deductions,
    :historical_election, :historical_limit, :historical_mode, :recurring_items_enabled

  def validate_annual_limit!
    return if historical_mode || !recurring_items_enabled || !active_election?
    return if election[:election_id].blank? || annual_limit.present?

    raise ArgumentError,
      "Retirement limits are not configured for #{payroll_item.pay_period.pay_date.year}. Add the verified annual limits before processing payroll."
  end

  def election
    @election ||= if historical_election.present?
      historical_election
    elsif (record = employee.retirement_election_on(payroll_item.pay_period.pay_date))
      record.snapshot_attributes.deep_symbolize_keys
    elsif employee.employee_retirement_elections.exists?
      legacy_election.merge(
        source: "before_first_dated_election",
        eligible: false,
        participating: false,
        traditional_rate: 0.to_d,
        roth_rate: 0.to_d,
        employer_match_mode: "none"
      )
    else
      legacy_election
    end
  end

  def legacy_election
    {
      election_id: nil,
      effective_on: nil,
      source: "legacy_employee_profile",
      plan_name: "Legacy retirement setup",
      eligible: true,
      participating: true,
      traditional_contribution_type: "percentage",
      traditional_rate: employee.retirement_rate.to_d,
      traditional_amount: 0.to_d,
      roth_contribution_type: "percentage",
      roth_rate: employee.roth_retirement_rate.to_d,
      roth_amount: 0.to_d,
      eligible_compensation: "gross_wages",
      catch_up_enabled: false,
      limit_priority: "proportional",
      plan_annual_employee_limit: nil,
      employer_match_mode: "legacy",
      legacy_employer_retirement_match_rate: employee.employer_retirement_match_rate.to_d,
      legacy_employer_roth_match_rate: employee.employer_roth_match_rate.to_d,
      employer_match_rate: 0.to_d,
      employer_match_deferral_cap_rate: nil,
      employer_match_period_cap: nil,
      employer_match_annual_cap: nil,
      employer_match_ytd_before_system: 0.to_d,
      employer_match_destination: "traditional",
      true_up_policy: "none"
    }
  end

  def annual_limit
    return historical_limit if historical_mode

    @annual_limit ||= if historical_limit.present?
      historical_limit
    elsif (record = AnnualRetirementLimit.for_pay_date(payroll_item.pay_period.pay_date))
      {
        id: record.id,
        tax_year: record.tax_year,
        elective_deferral_limit: record.elective_deferral_limit,
        catch_up_limit: record.catch_up_limit,
        enhanced_catch_up_limit: record.enhanced_catch_up_limit,
        roth_catch_up_wage_threshold: record.roth_catch_up_wage_threshold,
        source_name: record.source_name,
        source_url: record.source_url
      }
    end
  end

  def contribution_sources
    @contribution_sources ||= begin
      traditional = configured_amount(:traditional)
      roth = configured_amount(:roth)
      sources = [
        source(:built_in_traditional, :traditional, traditional),
        source(:built_in_roth, :roth, roth)
      ]

      payroll_item.payroll_item_field_entries.each do |entry|
        next unless entry.active? && entry.kind == "deduction" && entry.employee_paid?

        group = retirement_group_for_field(entry)
        next unless group

        sources << source("field:#{entry.object_id}", group, entry.amount.to_d, record: entry)
      end

      employee_deductions.each do |deduction|
        group = retirement_group_for_deduction(deduction)
        next unless group

        sources << source("deduction:#{deduction.object_id}", group, deduction.calculate_amount(payroll_item.gross_pay).to_d, record: deduction)
      end
      sources
    end
  end

  def source(key, bucket, requested, record: nil)
    { key: key.to_s, bucket: bucket, requested: [ requested, 0.to_d ].max.round(2), applied: 0.to_d, record: record }
  end

  def configured_amount(bucket)
    return 0.to_d unless recurring_items_enabled && active_election?

    type = election.fetch("#{bucket}_contribution_type".to_sym, "percentage")
    if type == "fixed"
      election.fetch("#{bucket}_amount".to_sym, 0).to_d
    else
      (eligible_compensation * election.fetch("#{bucket}_rate".to_sym, 0).to_d).round(2)
    end
  end

  def active_election?
    ActiveModel::Type::Boolean.new.cast(election.fetch(:eligible, true)) &&
      ActiveModel::Type::Boolean.new.cast(election.fetch(:participating, true))
  end

  def eligible_compensation
    @eligible_compensation ||= begin
      gross = payroll_item.gross_pay.to_d
      value = case election.fetch(:eligible_compensation, "gross_wages")
      when "gross_excluding_tips"
        gross - payroll_item.reported_tips.to_d
      when "base_pay"
        gross - payroll_item.reported_tips.to_d - payroll_item.service_charge_wages.to_d - payroll_item.bonus.to_d - custom_earnings_total
      else
        gross
      end
      [ value, 0.to_d ].max.round(2)
    end
  end

  def custom_earnings_total
    Array(payroll_item.custom_earnings).sum { |earning| earning["amount"].to_d } +
      payroll_item.taxable_payroll_adjustments_total.to_d + payroll_item.taxable_payroll_field_entries_total.to_d
  end

  def retirement_group_for_field(entry)
    group = PayrollReportingGroups.infer_retirement_group(
      explicit_group: entry.reporting_group.presence || entry.payroll_field_definition&.reporting_group,
      label: entry.label, category: entry.category, tax_treatment: entry.tax_treatment
    )
    bucket_for_group(group)
  end

  def retirement_group_for_deduction(deduction)
    type = deduction.deduction_type
    group = PayrollReportingGroups.infer_retirement_group(
      explicit_group: type.reporting_group, label: type.name, category: type.sub_category,
      deduction_category: type.category
    )
    bucket_for_group(group)
  end

  def bucket_for_group(group)
    case group
    when PayrollReportingGroups::GROUP_401K_PRE_TAX then :traditional
    when PayrollReportingGroups::GROUP_401K_AFTER_TAX then :roth
    end
  end

  def totals_for(sources, attribute)
    sources.each_with_object({ traditional: 0.to_d, roth: 0.to_d }) do |entry, totals|
      totals[entry[:bucket]] += entry.fetch(attribute)
    end.transform_values { |amount| amount.round(2) }
  end

  def allocate(requested)
    return { traditional: 0.to_d, roth: 0.to_d } unless recurring_items_enabled && active_election?

    total_requested = requested.values.sum
    target = [ total_requested, available_employee_deferral, eligible_compensation ].min.round(2)
    return { traditional: 0.to_d, roth: 0.to_d } unless target.positive?

    if roth_catch_up_required?
      base_remaining = [ annual_limit.fetch(:elective_deferral_limit).to_d - ytd_employee_deferral, 0.to_d ].max
      traditional = [ requested[:traditional], target, base_remaining ].min
      roth = [ requested[:roth], target - traditional ].min
      return { traditional: traditional.round(2), roth: roth.round(2) }
    end

    allocate_by_priority(requested, target)
  end

  def allocate_by_priority(requested, target)
    case election.fetch(:limit_priority, "proportional")
    when "traditional_first"
      traditional = [ requested[:traditional], target ].min
      { traditional: traditional, roth: [ requested[:roth], target - traditional ].min }
    when "roth_first"
      roth = [ requested[:roth], target ].min
      { traditional: [ requested[:traditional], target - roth ].min, roth: roth }
    else
      proportional_allocation(requested, target)
    end.transform_values { |amount| amount.round(2) }
  end

  def proportional_allocation(requested, target)
    total = requested.values.sum
    return { traditional: 0.to_d, roth: 0.to_d } unless total.positive?

    traditional = [ (target * requested[:traditional] / total).round(2), requested[:traditional] ].min
    roth = [ target - traditional, requested[:roth] ].min.round(2)
    traditional = [ target - roth, requested[:traditional] ].min.round(2)
    { traditional: traditional, roth: roth }
  end

  def available_employee_deferral
    return eligible_compensation unless annual_limit

    statutory = annual_limit.fetch(:elective_deferral_limit).to_d
    statutory += catch_up_limit if catch_up_available?
    plan_limit = election[:plan_annual_employee_limit].presence&.to_d
    annual_cap = plan_limit&.positive? ? [ statutory, plan_limit ].min : statutory
    [ annual_cap - ytd_employee_deferral, 0.to_d ].max
  end

  def catch_up_available?
    ActiveModel::Type::Boolean.new.cast(election[:catch_up_enabled]) && age_at_year_end && age_at_year_end >= 50
  end

  def catch_up_limit
    return 0.to_d unless annual_limit
    return annual_limit.fetch(:enhanced_catch_up_limit).to_d if age_at_year_end.between?(60, 63)

    annual_limit.fetch(:catch_up_limit).to_d
  end

  def age_at_year_end
    return nil unless employee.date_of_birth

    payroll_item.pay_period.pay_date.year - employee.date_of_birth.year
  end

  def roth_catch_up_required?
    return @roth_catch_up_required if defined?(@roth_catch_up_required)
    return @roth_catch_up_required = false unless annual_limit && catch_up_available? && election[:election_id].present?
    unless ytd_employee_deferral + contribution_sources.sum { |entry| entry[:requested] } > annual_limit.fetch(:elective_deferral_limit).to_d
      return @roth_catch_up_required = false
    end

    @roth_catch_up_required = prior_year_fica_wages > annual_limit.fetch(:roth_catch_up_wage_threshold).to_d
  end
  def prior_year_fica_wages
    @prior_year_fica_wages ||= employee.ytd_totals_through(
      year: payroll_item.pay_period.pay_date.year - 1,
      pay_date: Date.new(payroll_item.pay_period.pay_date.year - 1, 12, 31),
      pay_period_id: 9_223_372_036_854_775_807
    )[:social_security_taxable_total].to_d
  end

  def ytd_employee_deferral
    ytd_before.fetch(:retirement, 0).to_d + ytd_before.fetch(:roth_retirement, 0).to_d
  end

  def apply_source_caps!(sources, allowed)
    @deduction_amounts = {}
    %i[traditional roth].each do |bucket|
      bucket_sources = sources.select { |entry| entry[:bucket] == bucket }
      distribute_to_sources!(bucket_sources, allowed.fetch(bucket))
    end

    payroll_item.retirement_payment = sources.find { |entry| entry[:key] == "built_in_traditional" }[:applied]
    payroll_item.roth_retirement_payment = sources.find { |entry| entry[:key] == "built_in_roth" }[:applied]
  end

  def distribute_to_sources!(sources, allowed)
    total = sources.sum { |entry| entry[:requested] }
    remaining = allowed
    sources.each_with_index do |entry, index|
      amount = if index == sources.length - 1
        [ remaining, entry[:requested] ].min
      elsif total.positive?
        [ (allowed * entry[:requested] / total).round(2), entry[:requested], remaining ].min
      else
        0.to_d
      end
      entry[:applied] = amount.round(2)
      remaining -= entry[:applied]
      apply_source_amount!(entry)
    end
  end

  def apply_source_amount!(entry)
    record = entry[:record]
    return unless record

    if record.is_a?(PayrollItemFieldEntry)
      metadata = record.metadata.to_h
      metadata["uncapped_amount"] = entry[:requested].to_s("F") if entry[:requested] != entry[:applied]
      metadata.delete("uncapped_amount") if entry[:requested] == entry[:applied]
      record.amount = entry[:applied]
      record.metadata = metadata
    else
      @deduction_amounts[record.object_id] = entry[:applied]
    end
  end

  def apply_employer_match!(employee_applied)
    if !recurring_items_enabled || !active_election?
      payroll_item.employer_retirement_match = 0
      payroll_item.employer_roth_retirement_match = 0
      return
    end

    if election[:employer_match_mode] == "legacy"
      payroll_item.employer_retirement_match = (payroll_item.gross_pay.to_d * election.fetch(:legacy_employer_retirement_match_rate, 0).to_d).round(2)
      payroll_item.employer_roth_retirement_match = (payroll_item.gross_pay.to_d * election.fetch(:legacy_employer_roth_match_rate, 0).to_d).round(2)
      return
    end

    match = calculated_match(employee_applied.values.sum)
    if election[:employer_match_destination] == "roth"
      payroll_item.employer_retirement_match = 0
      payroll_item.employer_roth_retirement_match = match
    else
      payroll_item.employer_retirement_match = match
      payroll_item.employer_roth_retirement_match = 0
    end
  end

  def calculated_match(current_employee_deferral)
    rate = election.fetch(:employer_match_rate, 0).to_d
    return 0.to_d unless rate.positive? && election[:employer_match_mode] != "none"

    if election[:true_up_policy] == "year_to_date"
      match_basis = match_basis_amount(ytd_employee_deferral + current_employee_deferral, ytd_before.fetch(:gross_pay, 0).to_d + eligible_compensation)
      requested = (match_basis * rate).round(2) - prior_employer_match
    else
      requested = (match_basis_amount(current_employee_deferral, eligible_compensation) * rate).round(2)
    end

    requested = [ requested, 0.to_d ].max
    period_cap = election[:employer_match_period_cap].presence&.to_d
    requested = [ requested, period_cap ].min if period_cap&.positive?
    annual_cap = election[:employer_match_annual_cap].presence&.to_d
    requested = [ requested, [ annual_cap - prior_employer_match, 0.to_d ].max ].min if annual_cap&.positive?
    requested.round(2)
  end

  def match_basis_amount(employee_deferral, compensation)
    return compensation if election[:employer_match_mode] == "compensation_percentage"

    cap_rate = election[:employer_match_deferral_cap_rate].presence&.to_d
    cap_rate&.positive? ? [ employee_deferral, compensation * cap_rate ].min : employee_deferral
  end

  def prior_employer_match
    @prior_employer_match ||= begin
      period = payroll_item.pay_period
      live = employee.payroll_items.joins(:pay_period).not_voided
        .where(pay_periods: { id: PayPeriod.reportable_committed.where(company_id: period.company_id, pay_date: Date.new(period.pay_date.year, 1, 1)..period.pay_date).select(:id) })
        .where("pay_periods.pay_date < ? OR (pay_periods.pay_date = ? AND pay_periods.id < ?)", period.pay_date, period.pay_date, period.id)
        .sum("payroll_items.employer_retirement_match + payroll_items.employer_roth_retirement_match").to_d
      effective_on = election[:effective_on].presence&.to_date
      imported = effective_on&.year == period.pay_date.year ? election.fetch(:employer_match_ytd_before_system, 0).to_d : 0.to_d
      live + imported
    end
  end

  def build_snapshot(requested:, applied:, sources:)
    reasons = []
    reasons << "Recurring retirement items are excluded from this supplemental payroll." unless recurring_items_enabled
    reasons << "This employee is not eligible or is not participating in the plan." unless active_election?
    if ActiveModel::Type::Boolean.new.cast(election[:catch_up_enabled]) && employee.date_of_birth.blank?
      reasons << "Catch-up contributions were not applied because the employee's date of birth is missing."
    end
    if requested.values.sum > applied.values.sum
      reasons << "Employee contributions were reduced by the current-pay compensation or annual plan limit."
    end
    if roth_catch_up_required? && requested[:traditional] > applied[:traditional]
      reasons << "Traditional contributions above the base limit were excluded because this employee's catch-up contributions must be Roth."
    end
    reasons << "No annual retirement limit is configured for this pay date; only current eligible compensation was enforced." unless annual_limit

    {
      "version" => 1,
      "calculated_at" => Time.current.iso8601,
      "election" => serialize_hash(election),
      "annual_limit" => annual_limit ? serialize_hash(annual_limit) : nil,
      "employee_age_at_year_end" => age_at_year_end,
      "eligible_compensation" => eligible_compensation.to_s("F"),
      "ytd_employee_deferral_before" => ytd_employee_deferral.to_s("F"),
      "prior_year_fica_wages" => roth_catch_up_required? ? prior_year_fica_wages.to_s("F") : nil,
      "roth_catch_up_required" => roth_catch_up_required?,
      "requested" => serialize_hash(requested),
      "applied" => serialize_hash(applied),
      "employer_match" => {
        "traditional" => payroll_item.employer_retirement_match.to_d.to_s("F"),
        "roth" => payroll_item.employer_roth_retirement_match.to_d.to_s("F"),
        "prior_ytd" => prior_employer_match.to_s("F")
      },
      "sources" => sources.map { |entry| entry.except(:record).transform_values { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value } },
      "explanations" => reasons
    }
  end

  def serialize_hash(hash)
    hash.transform_keys(&:to_s).transform_values do |value|
      case value
      when BigDecimal then value.to_s("F")
      when Date then value.iso8601
      else value
      end
    end
  end
end
