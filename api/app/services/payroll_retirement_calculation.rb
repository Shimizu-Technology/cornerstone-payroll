# frozen_string_literal: true

# Applies one effective-dated employee retirement election across the built-in
# percentage/fixed fields and the flexible payroll-field/deduction paths. The
# result is capped as one combined employee elective deferral and preserved on
# the paycheck so an operator can explain every exclusion and cap later.
class PayrollRetirementCalculation
  Result = Data.define(:deduction_amounts, :snapshot)

  def initialize(employee:, payroll_item:, ytd_before:, employee_deductions:, historical_election: nil,
                 historical_limit: nil, historical_evidence: nil, defer_additions: false, historical_mode: false, recurring_items_enabled: true)
    @employee = employee
    @payroll_item = payroll_item
    evidence = historical_evidence&.deep_symbolize_keys || {}
    @ytd_before = historical_mode && evidence[:ytd_before].present? ? evidence[:ytd_before] : ytd_before
    @employee_deductions = employee_deductions
    @historical_election = historical_election&.deep_symbolize_keys
    @historical_limit = historical_limit&.deep_symbolize_keys
    @defer_additions = defer_additions
    @historical_evidence = evidence
    @historical_mode = historical_mode
    @recurring_items_enabled = recurring_items_enabled
  end

  def apply!
    sources = contribution_sources
    validate_annual_limit!
    validate_plan!
    requested = totals_for(sources, :requested)
    allowed = allocate(requested)
    apply_source_caps!(sources, allowed)
    applied = totals_for(sources, :applied)
    apply_employer_match!(applied)
    validate_employer_sources!
    validate_annual_additions!(applied) unless @defer_additions

    snapshot = build_snapshot(requested:, applied:, sources:)
    payroll_item.retirement_rule_snapshot = snapshot
    Result.new(deduction_amounts: @deduction_amounts || {}, snapshot: snapshot)
  end

  def reconcile_final!
    applied = PayrollRetirementTotals.for_item(payroll_item).then do |totals|
      { traditional: totals[:retirement], roth: totals[:roth_retirement],
        non_roth_after_tax: PayrollRetirementTotals.additions_for_item(payroll_item)[:non_roth_after_tax] }
    end
    apply_employer_match!(applied)
    validate_employer_sources!
    validate_annual_additions!(applied)
    snapshot = payroll_item.retirement_rule_snapshot.to_h.deep_dup
    previous = snapshot.fetch("applied", {})
    snapshot["applied"] = serialize_hash(applied)
    snapshot["annual_additions"] = serialize_hash(@annual_additions || {})
    snapshot["remaining_after"] = [ available_employee_deferral(include_pending_catch_up: false) - applied.slice(:traditional, :roth).values.sum, 0.to_d ].max.to_s("F")
    snapshot["catch_up_amount"] = ((@annual_additions || {}).fetch(:prior_catch_up, 0).to_d + (@annual_additions || {}).fetch(:current_catch_up, 0).to_d).to_s("F")
    snapshot["employer_match"] = { "traditional" => payroll_item.employer_retirement_match.to_d.to_s("F"),
      "roth" => payroll_item.employer_roth_retirement_match.to_d.to_s("F"), "prior_ytd" => prior_employer_match.to_s("F") }
    if previous != snapshot["applied"]
      snapshot["explanations"] = Array(snapshot["explanations"]) | [ "Employee contributions were reduced because the paycheck did not have enough available pay." ]
    end
    snapshot["sources"] = Array(snapshot["sources"]).map do |saved|
      source = contribution_sources.find { |candidate| candidate[:key] == saved["key"] }
      next saved unless source
      amount = case source[:key]
      when "built_in_traditional" then payroll_item.retirement_payment
      when "built_in_roth" then payroll_item.roth_retirement_payment
      else
        if source[:record].is_a?(PayrollItemFieldEntry)
          source[:record].amount
        else
          payroll_item.payroll_item_deductions.select { |row| row.deduction_type_id == source[:record].deduction_type_id && !row.employer_contribution? }.sum(&:amount)
        end
      end
      saved.merge("applied" => amount.to_d.to_s("F"))
    end
    payroll_item.retirement_rule_snapshot = snapshot
  end

  private

  attr_reader :employee, :payroll_item, :ytd_before, :employee_deductions,
    :historical_election, :historical_limit, :historical_evidence, :historical_mode, :recurring_items_enabled

  def retirement_requested?
    contribution_sources.any? { |entry| entry[:requested].positive? } || employer_sources_total.positive? ||
      (recurring_items_enabled && active_election? && (eligible_compensation.positive? || election[:true_up_policy] == "year_to_date") && (
        election.fetch(:employer_match_rate, 0).to_d.positive? ||
        election.fetch(:legacy_employer_retirement_match_rate, 0).to_d.positive? ||
        election.fetch(:legacy_employer_roth_match_rate, 0).to_d.positive?))
  end

  def validate_annual_limit!
    return unless retirement_requested?
    # Old historical snapshots retain their original rules; new snapshots must
    # carry the entire rule set rather than consulting today's configuration.
    return if historical_mode && historical_evidence.fetch(:version, 1).to_i < 2
    return if annual_limit && %i[elective_deferral_limit annual_additions_limit compensation_limit].all? { |key| annual_limit[key].to_d.positive? }

    raise ArgumentError, "Retirement limits are not configured for #{tax_year}. Add the verified annual limits before processing payroll."
  end

  def validate_plan!
    return if historical_mode || !retirement_requested?
    if election.fetch(:plan_type, "standard_401k") != "standard_401k" ||
        election.fetch(:limitation_year_type, "calendar") != "calendar" || election[:related_plan_review_required]
      raise ArgumentError, "This retirement plan requires administrator review: only standard 401(k) plans with a calendar limitation year and no unresolved related-plan limits can be calculated."
    end
    if election[:catch_up_enabled] && (employee.date_of_birth.blank? || election[:plan_source_reference].blank?)
      raise ArgumentError, "Verify the employee's date of birth and the plan document reference before enabling catch-up contributions."
    end
    if contribution_sources.any? { |entry| entry[:bucket] == :roth && entry[:requested].positive? } &&
        (!election[:roth_available] || election[:plan_source_reference].blank?)
      raise ArgumentError, "Verify that the plan permits designated Roth employee contributions before calculating this paycheck."
    end
  end

  def tax_year
    payroll_item.pay_period.pay_date.year
  end

  def year_input
    @year_input ||= if historical_mode
      historical_evidence[:year_input].to_h
    else
      employee.retirement_year_input_for(tax_year)&.snapshot_attributes&.deep_symbolize_keys || {}
    end
  end

  def election
    @election ||= if historical_election.present?
      historical_election
    elsif (record = employee.retirement_election_on(payroll_item.pay_period.pay_date))
      record.snapshot_attributes.deep_symbolize_keys
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
        annual_additions_limit: record.annual_additions_limit,
        compensation_limit: record.compensation_limit,
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
        next unless deduction.deduction_type.active? && deduction.deduction_type.category.in?(%w[pre_tax post_tax])
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
    when PayrollReportingGroups::GROUP_401K_NON_ROTH_AFTER_TAX then :non_roth_after_tax
    end
  end

  def totals_for(sources, attribute)
    sources.each_with_object({ traditional: 0.to_d, roth: 0.to_d, non_roth_after_tax: 0.to_d }) do |entry, totals|
      totals[entry[:bucket]] += entry.fetch(attribute)
    end.transform_values { |amount| amount.round(2) }
  end

  def allocate(requested)
    empty = { traditional: 0.to_d, roth: 0.to_d, non_roth_after_tax: 0.to_d }
    return empty unless recurring_items_enabled && active_election?

    elective = requested.slice(:traditional, :roth)
    target = [ elective.values.sum, available_employee_deferral, eligible_compensation ].min.round(2)
    allocation = allocate_by_priority(elective, target)
    if target.positive? && attempted_catch_up?(target)
      validate_catch_up_evidence!
      if roth_catch_up_required?
        # Earlier designated Roth deferrals already satisfy the annual Roth
        # catch-up requirement; they do not consume Traditional capacity twice.
        traditional_room = [ [ annual_limit.fetch(:elective_deferral_limit).to_d - ytd_employee_deferral + ytd_before.fetch(:roth_retirement, 0).to_d,
          regular_deferral_limit - ytd_before.fetch(:retirement, 0).to_d ].min, 0.to_d ].max
        allocation[:traditional] = [ allocation[:traditional], traditional_room ].min
        allocation[:roth] = [ elective[:roth], target - allocation[:traditional] ].min
      end
    end
    allocation[:non_roth_after_tax] = [ requested[:non_roth_after_tax], [ eligible_compensation - allocation.values.sum, 0.to_d ].max ].min
    allocation.transform_values { |amount| amount.round(2) }
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

  def available_employee_deferral(include_pending_catch_up: true)
    return eligible_compensation unless annual_limit

    permitted = catch_up_available? || (include_pending_catch_up && catch_up_permission_status == "prior_wages_pending")
    catch_up = permitted ? catch_up_limit : 0.to_d
    personal_remaining = annual_limit.fetch(:elective_deferral_limit).to_d + catch_up - ytd_employee_deferral
    local_remaining = regular_deferral_limit + catch_up - local_employee_deferral_before
    plan_limit = optional_cap(:plan_annual_employee_limit)
    local_remaining = [ local_remaining, plan_limit - local_employee_deferral_before ].min unless plan_limit.nil?
    [ [ personal_remaining, local_remaining ].min, 0.to_d ].max
  end

  def annual_employee_cap
    cap = regular_deferral_limit + (catch_up_available? ? catch_up_limit : 0.to_d)
    plan_limit = optional_cap(:plan_annual_employee_limit)
    plan_limit.nil? ? cap : [ cap, plan_limit ].min
  end

  def catch_up_age_eligible?
    ActiveModel::Type::Boolean.new.cast(election[:catch_up_enabled]) && age_at_year_end && age_at_year_end >= 50
  end

  def catch_up_available?
    catch_up_permission_status == "permitted"
  end

  def catch_up_permission_status
    return "ineligible" unless catch_up_age_eligible?
    return "permitted" if tax_year < 2026 || (historical_mode && historical_evidence.fetch(:version, 1).to_i < 2)
    return "prior_wages_pending" unless year_input[:prior_year_wage_status].in?(%w[verified no_prior_employer_wages]) && year_input[:prior_year_wage_source].present?
    if prior_year_fica_wages > annual_limit.fetch(:roth_catch_up_wage_threshold).to_d && !election[:roth_available]
      return "roth_unavailable"
    end

    "permitted"
  end

  def catch_up_limit
    return 0.to_d unless annual_limit
    return annual_limit.fetch(:enhanced_catch_up_limit).to_d if age_at_year_end.between?(60, 63)

    annual_limit.fetch(:catch_up_limit).to_d
  end

  def age_at_year_end
    return historical_evidence[:employee_age_at_year_end] if historical_mode
    return nil unless employee.date_of_birth

    tax_year - employee.date_of_birth.year
  end

  def optional_cap(attribute)
    value = election[attribute].presence&.to_d
    # Version-one snapshots were calculated with zero treated as no cap.
    # Reproduce that saved behavior instead of silently rewriting corrections.
    return nil if historical_mode && historical_evidence.fetch(:version, 1).to_i < 2 && value == 0

    value
  end

  def regular_deferral_limit
    return eligible_compensation unless annual_limit

    limit = annual_limit.fetch(:elective_deferral_limit).to_d
    plan = optional_cap(:regular_plan_deferral_limit)
    plan.nil? ? limit : [ limit, plan ].min
  end

  def attempted_catch_up?(current)
    return false unless annual_limit
    ytd_employee_deferral + current > annual_limit.fetch(:elective_deferral_limit).to_d ||
      local_employee_deferral_before + current > regular_deferral_limit
  end

  def validate_catch_up_evidence!
    if year_input.fetch(:external_traditional_deferrals, 0).to_d.positive?
      raise ArgumentError, "Catch-up with outside-employer Traditional deferrals requires administrator review of those amounts and their catch-up classification. Confirm the personal limit and sponsor-specific Roth treatment before processing this paycheck."
    end
    return if tax_year < 2026 || (historical_mode && historical_evidence.fetch(:version, 1).to_i < 2)
    return if year_input[:prior_year_wage_status].in?(%w[verified no_prior_employer_wages]) && year_input[:prior_year_wage_source].present?

    raise ArgumentError, "Catch-up contributions require verified prior-year employer Social Security wages (W-2 Box 3), or verified evidence of no prior-year employer wages. Add the retirement year evidence and recalculate."
  end

  def roth_catch_up_required?
    return false unless annual_limit && catch_up_age_eligible? && tax_year >= 2026
    return historical_evidence[:roth_catch_up_required] if historical_mode && historical_evidence.fetch(:version, 1).to_i < 2

    prior_year_fica_wages > annual_limit.fetch(:roth_catch_up_wage_threshold).to_d
  end

  def prior_year_fica_wages
    return historical_evidence[:prior_year_fica_wages].to_d if historical_mode && year_input.empty?

    year_input.fetch(:prior_year_fica_wages, 0).to_d
  end

  def ytd_employee_deferral
    ytd_before.fetch(:retirement, 0).to_d + ytd_before.fetch(:roth_retirement, 0).to_d +
      year_input.fetch(:external_traditional_deferrals, 0).to_d + year_input.fetch(:external_roth_deferrals, 0).to_d
  end

  def apply_source_caps!(sources, allowed)
    @deduction_amounts = {}
    %i[traditional roth non_roth_after_tax].each do |bucket|
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
      payroll_item.employer_retirement_match = (match_compensation * election.fetch(:legacy_employer_retirement_match_rate, 0).to_d).round(2)
      payroll_item.employer_roth_retirement_match = (match_compensation * election.fetch(:legacy_employer_roth_match_rate, 0).to_d).round(2)
      return
    end

    match = calculated_match(employee_applied.slice(:traditional, :roth).values.sum)
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

    if historical_mode && historical_evidence.fetch(:version, 1).to_i < 2 && election[:true_up_policy] == "year_to_date"
      match_basis = match_basis_amount(local_employee_deferral_before + current_employee_deferral, ytd_before.fetch(:gross_pay, 0).to_d + eligible_compensation)
      requested = (match_basis * rate).round(2) - prior_employer_match
    elsif election[:true_up_policy] == "year_to_date"
      match_basis = match_basis_amount(local_employee_deferral_before + current_employee_deferral, [ prior_eligible_compensation + eligible_compensation, compensation_limit ].min)
      requested = (match_basis * rate).round(2) - prior_employer_match
    else
      requested = (match_basis_amount(current_employee_deferral, match_compensation) * rate).round(2)
    end

    requested = [ requested, 0.to_d ].max
    period_cap = optional_cap(:employer_match_period_cap)
    requested = [ requested, period_cap ].min unless period_cap.nil?
    annual_cap = optional_cap(:employer_match_annual_cap)
    requested = [ requested, [ annual_cap - prior_employer_match, 0.to_d ].max ].min unless annual_cap.nil?
    requested.round(2)
  end

  def match_basis_amount(employee_deferral, compensation)
    return compensation if election[:employer_match_mode] == "compensation_percentage"

    cap_rate = optional_cap(:employer_match_deferral_cap_rate)
    cap_rate.nil? ? employee_deferral : [ employee_deferral, compensation * cap_rate ].min
  end

  def election_opening_match
    effective_on = election[:effective_on].presence&.to_date
    effective_on&.year == tax_year ? election.fetch(:employer_match_ytd_before_system, 0).to_d : 0.to_d
  end

  def prior_employer_match
    return historical_evidence.dig(:employer_match, :prior_ytd).to_d if historical_mode
    @prior_employer_match ||= begin
      period = payroll_item.pay_period
      live = employee.payroll_items.joins(:pay_period).not_voided.reportable
        .where(pay_periods: { id: PayPeriod.reportable_for_company(period.company).where(pay_date: Date.new(period.pay_date.year, 1, 1)..period.pay_date).select(:id) })
        .where("pay_periods.pay_date < ? OR (pay_periods.pay_date = ? AND pay_periods.id < ?)", period.pay_date, period.pay_date, period.id)
        .sum("payroll_items.employer_retirement_match + payroll_items.employer_roth_retirement_match").to_d
      effective_on = election[:effective_on].presence&.to_date
      imported = effective_on&.year == period.pay_date.year ? election.fetch(:employer_match_ytd_before_system, 0).to_d : 0.to_d
      live + imported
    end
  end

  def local_employee_deferral_before
    ytd_before.fetch(:retirement, 0).to_d + ytd_before.fetch(:roth_retirement, 0).to_d
  end

  def prior_payroll_items
    @prior_payroll_items ||= begin
      period = payroll_item.pay_period
      employee.payroll_items.joins(:pay_period).not_voided.reportable
        .where(pay_periods: { id: PayPeriod.reportable_for_company(period.company).where(pay_date: Date.new(tax_year, 1, 1)..period.pay_date).select(:id) })
        .where("pay_periods.pay_date < ? OR (pay_periods.pay_date = ? AND pay_periods.id < ?)", period.pay_date, period.pay_date, period.id)
        .includes(:payroll_item_field_entries, payroll_item_deductions: :deduction_type).to_a
    end
  end

  def compensation_limit
    annual_limit&.fetch(:compensation_limit, nil)&.to_d || eligible_compensation
  end

  def prior_eligible_compensation
    return historical_evidence.dig(:annual_additions, :prior_eligible_compensation).to_d if historical_mode

    @prior_eligible_compensation ||= begin
      restricted = election.fetch(:eligible_compensation, "gross_wages") != "gross_wages"
      if restricted
        if prior_payroll_items.any? { |item| item.retirement_rule_snapshot.dig("election", "eligible_compensation") != election[:eligible_compensation] } ||
            (ytd_before.fetch(:gross_pay, 0).to_d > prior_payroll_items.sum { |item| item.gross_pay.to_d } && !year_input[:opening_balances_verified])
          raise ArgumentError, "Restricted retirement compensation history is incomplete. Verify the opening eligible compensation and prior plan compensation before calculating matching or a true-up."
        end
        prior_payroll_items.sum { |item| item.retirement_rule_snapshot["eligible_compensation"].to_d } + year_input.fetch(:eligible_compensation_before_system, 0).to_d
      else
        ytd_before.fetch(:gross_pay, 0).to_d + year_input.fetch(:eligible_compensation_before_system, 0).to_d
      end
    end
  end

  def match_compensation
    [ eligible_compensation, [ compensation_limit - prior_eligible_compensation, 0.to_d ].max ].min
  end

  def flexible_employer_sources
    fields = payroll_item.payroll_item_field_entries.filter_map do |entry|
      next unless entry.active? && entry.employer_contribution?
      bucket = retirement_group_for_field(entry)
      next unless bucket && entry.amount.to_d.positive?

      { label: entry.label, bucket: bucket, amount: entry.amount.to_d,
        percentage: entry.payroll_field_definition&.amount_type == "percentage" }
    end
    recurring = employee_deductions.filter_map do |assignment|
      type = assignment.deduction_type
      next unless type.active? && type.employer_contribution?
      bucket = retirement_group_for_deduction(assignment)
      amount = assignment.calculate_amount(payroll_item.gross_pay).to_d
      next unless bucket && amount.positive?

      { label: type.name, bucket: bucket, amount: amount, percentage: assignment.is_percentage? }
    end
    fields + recurring
  end

  def employer_sources_total
    flexible_employer_sources.sum { |source| source[:amount] }
  end

  def validate_employer_sources!
    return if historical_mode

    sources = flexible_employer_sources
    roth_requested = payroll_item.employer_roth_retirement_match.to_d.positive? || sources.any? { |source| source[:bucket] == :roth }
    if roth_requested && (!election[:employer_roth_available] || election[:plan_source_reference].blank?)
      raise ArgumentError, "Verify designated Roth employer contribution support and provider reporting in an effective retirement plan election before processing legacy or flexible Roth employer contributions."
    end
    percentage_sources = sources.select { |source| source[:percentage] }
    return if percentage_sources.empty? || payroll_item.gross_pay.to_d <= match_compensation

    labels = percentage_sources.map { |source| source[:label] }.uniq.join(", ")
    raise ArgumentError, "Employer retirement percentage contributions (#{labels}) use gross pay outside the permitted compensation basis or annual compensation ceiling. Move these contributions into a verified capped employer-match election, or obtain administrator review of the contribution basis before processing."
  end

  def prior_additions
    return historical_evidence.dig(:annual_additions, :prior_additions).to_d if historical_mode

    @prior_additions ||= begin
      components = prior_payroll_items.map { |item| PayrollRetirementTotals.additions_for_item(item) }
      bridge = employee.send(:applied_historical_ytd_balance, tax_year)
      breakdown = bridge&.source_breakdown.to_h
      imported_employer = breakdown.fetch("employer_contribution_breakdown", {}).to_h.sum do |label, amount|
        group = PayrollReportingGroups.infer_retirement_group(label: label, deduction_category: "employer_contribution")
        if group == PayrollReportingGroups::GROUP_RETIREMENT_OTHER && label.match?(/401\s*\(?k\)?/i)
          raise ArgumentError, "The applied historical retirement bridge has ambiguous employer contribution labels. Verify the retained classification before calculating annual additions."
        end
        group && group != PayrollReportingGroups::GROUP_RETIREMENT_OTHER ? amount.to_d : 0.to_d
      end
      imported_after_tax = breakdown.fetch("after_tax_deduction_breakdown", {}).to_h.sum do |label, amount|
        group = PayrollReportingGroups.infer_retirement_group(label: label, deduction_category: "post_tax")
        if group == PayrollReportingGroups::GROUP_RETIREMENT_OTHER && label.match?(/401\s*\(?k\)?/i)
          raise ArgumentError, "The applied historical bridge has ambiguous after-tax 401(k) labels. Verify Roth versus non-Roth classification before calculating retirement contributions."
        end
        group == PayrollReportingGroups::GROUP_401K_NON_ROTH_AFTER_TAX ? amount.to_d : 0.to_d
      end
      # The older election opening match is an alternative statement of the
      # imported match. The new year-input amounts exclude the applied bridge.
      employer_opening = [ imported_employer, election_opening_match ].max +
        year_input.fetch(:employer_additions_before_system, 0).to_d
      local_employee_deferral_before + components.sum { |values| values[:employer] + values[:non_roth_after_tax] } +
        employer_opening + imported_after_tax + year_input.fetch(:non_roth_after_tax_before_system, 0).to_d
    end
  end

  def prior_catch_up
    return historical_evidence.dig(:annual_additions, :prior_catch_up).to_d if historical_mode

    saved = prior_payroll_items.sum { |item| item.retirement_rule_snapshot.dig("annual_additions", "current_catch_up").to_d }
    inferred = [ local_employee_deferral_before - regular_deferral_limit, 0.to_d ].max
    if inferred.positive? && !catch_up_available?
      raise ArgumentError, "Year-to-date deferrals exceed the regular retirement limit without verified catch-up eligibility. Reconcile the historical contributions with the plan administrator before processing more retirement contributions."
    end
    [ saved, inferred ].max
  end

  def validate_annual_additions!(applied)
    return unless retirement_requested? && annual_limit&.dig(:annual_additions_limit).to_d.positive?

    elective = applied.slice(:traditional, :roth).values.sum
    current_employer = payroll_item.employer_retirement_match.to_d + payroll_item.employer_roth_retirement_match.to_d + employer_sources_total
    if election.fetch(:eligible_compensation, "gross_wages") != "gross_wages" && year_input.fetch(:eligible_compensation_before_system, 0).to_d.positive?
      raise ArgumentError, "A restricted-compensation plan with additional opening compensation needs administrator review of statutory annual-additions compensation. The restricted matching basis cannot substitute for the statutory compensation record."
    end
    total_compensation = ytd_before.fetch(:gross_pay, 0).to_d + payroll_item.gross_pay.to_d + year_input.fetch(:eligible_compensation_before_system, 0).to_d
    limit = [ annual_limit[:annual_additions_limit].to_d, total_compensation ].min
    personal_base = annual_limit.fetch(:elective_deferral_limit).to_d
    prior_deferral_catch_up = [ ytd_employee_deferral - personal_base, local_employee_deferral_before - regular_deferral_limit, 0.to_d ].max
    current_personal_catch_up = [ ytd_employee_deferral + elective - personal_base,
      local_employee_deferral_before + elective - regular_deferral_limit, 0.to_d ].max - prior_deferral_catch_up
    current_additions = elective + applied.fetch(:non_roth_after_tax, 0).to_d + current_employer
    necessary_catch_up = [ prior_additions + current_additions - limit - prior_catch_up, current_personal_catch_up, 0.to_d ].max
    if necessary_catch_up.positive?
      validate_catch_up_evidence! if catch_up_permission_status == "prior_wages_pending"
      capacity = catch_up_available? ? [ catch_up_limit - prior_catch_up, 0.to_d ].max : 0.to_d
      if necessary_catch_up > capacity || necessary_catch_up > elective
        raise ArgumentError, "Retirement annual additions exceed the lesser of the statutory limit and compensation. Review employer contributions, opening balances and plan limits with the administrator; promised employer contributions cannot be silently reduced."
      end
      validate_catch_up_evidence!
      if roth_catch_up_required?
        # Earlier local Roth deferrals may satisfy catch-up; outside-employer
        # Roth cannot establish this employer's designated Roth compliance.
        roth_available = ytd_before.fetch(:roth_retirement, 0).to_d + applied[:roth]
        if roth_available < prior_catch_up + necessary_catch_up
          raise ArgumentError, "The annual additions limit requires catch-up classification, but this employee needs designated Roth catch-up. Review the elected Roth amount with the plan administrator."
        end
      end
    end
    @annual_additions = {
      limit: limit, prior_additions: prior_additions, prior_catch_up: prior_catch_up,
      current_additions: current_additions, current_catch_up: necessary_catch_up,
      current_employer: current_employer, current_non_roth_after_tax: applied.fetch(:non_roth_after_tax, 0).to_d,
      regular_additions_after: prior_additions + current_additions - prior_catch_up - necessary_catch_up,
      prior_eligible_compensation: prior_eligible_compensation, statutory_compensation: total_compensation,
      remaining: [ limit - prior_additions - current_additions + prior_catch_up + necessary_catch_up, 0.to_d ].max
    }
  end

  def build_snapshot(requested:, applied:, sources:)
    reasons = []
    reasons << "Recurring retirement items are excluded from this supplemental payroll." unless recurring_items_enabled
    reasons << "This employee is not eligible or is not participating in the plan." unless active_election?
    if catch_up_permission_status == "prior_wages_pending"
      reasons << "Potential catch-up eligibility requires verified prior-year employer wage evidence; permitted catch-up capacity is not established."
    elsif catch_up_permission_status == "roth_unavailable"
      reasons << "Catch-up contributions are unavailable because prior-year employer wages require designated Roth catch-up and this plan does not offer designated Roth employee contributions."
    end
    if ActiveModel::Type::Boolean.new.cast(election[:catch_up_enabled]) && age_at_year_end.nil?
      reasons << "Catch-up contributions were not applied because the employee's date of birth is missing."
    end
    if requested.values.sum > applied.values.sum
      reasons << "Employee contributions were reduced by the current-pay compensation or annual plan limit."
    end
    if roth_catch_up_required? && requested[:traditional] > applied[:traditional]
      reasons << "Traditional contributions were limited because the annual catch-up requirement must be satisfied with designated Roth contributions."
    end

    {
      "version" => historical_mode ? historical_evidence.fetch(:version, 1).to_i : 2,
      "calculated_at" => Time.current.iso8601,
      "election" => serialize_hash(election),
      "annual_limit" => annual_limit ? serialize_hash(annual_limit) : nil,
      "employee_age_at_year_end" => age_at_year_end,
      "year_input" => serialize_hash(year_input),
      "ytd_before" => serialize_hash(ytd_before),
      "regular_deferral_limit" => regular_deferral_limit.to_s("F"),
      "catch_up_permission_status" => catch_up_permission_status,
      "catch_up_age_eligible" => !!catch_up_age_eligible?,
      "potential_catch_up_limit" => (catch_up_age_eligible? ? catch_up_limit : 0.to_d).to_s("F"),
      "catch_up_limit" => (catch_up_available? ? catch_up_limit : 0.to_d).to_s("F"),
      "employee_deferral_limit" => (regular_deferral_limit + (catch_up_available? ? catch_up_limit : 0.to_d)).to_s("F"),
      "annual_employee_cap" => annual_employee_cap.to_s("F"),
      "remaining_after" => [ available_employee_deferral(include_pending_catch_up: false) - applied.slice(:traditional, :roth).values.sum, 0.to_d ].max.to_s("F"),
      "catch_up_amount" => ((@annual_additions || {}).fetch(:prior_catch_up, 0).to_d + (@annual_additions || {}).fetch(:current_catch_up, 0).to_d).to_s("F"),
      "annual_additions" => serialize_hash(@annual_additions || {}),
      "eligible_compensation" => eligible_compensation.to_s("F"),
      "ytd_employee_deferral_before" => ytd_employee_deferral.to_s("F"),
      "prior_year_fica_wages" => year_input.empty? ? nil : prior_year_fica_wages.to_s("F"),
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
