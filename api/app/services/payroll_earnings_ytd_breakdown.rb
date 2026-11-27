# frozen_string_literal: true

# Builds the earnings rows shown on a check stub and carries each row's YTD
# amount across the locked QuickBooks opening balance and reportable
# Cornerstone payroll. Historical source labels are matched exactly first and
# only fall back to a semantic bucket when there is a single unambiguous
# current row for that bucket.
class PayrollEarningsYtdBreakdown
  Row = Data.define(:label, :source_label, :category, :hours, :rate, :current, :ytd, :historical_only) do
    def initialize(label:, source_label:, category:, hours:, rate:, current:, ytd:, historical_only: false)
      super
    end
  end
  Component = Data.define(:label, :category, :hours, :rate, :amount)

  def initialize(payroll_item, sources: nil, employee_copy: false)
    @payroll_item = payroll_item
    @sources = sources || PayrollStatementYtdSources.new(payroll_item)
    @employee_copy = employee_copy
    @employee = payroll_item.employee
    @pay_period = payroll_item.pay_period
    @company = payroll_item.company
  end

  def call
    targets = current_components.map do |component|
      {
        component: component,
        semantic: semantic_for(component.category, component.label),
        ytd: 0.to_d,
        historical_only: false
      }
    end

    live_components.each { |component| add_to_target!(targets, component, semantic_fallback: false) }
    historical_components.each { |component| add_to_target!(targets, component, semantic_fallback: true, historical: true) }

    targets.map do |target|
      component = target.fetch(:component)
      historical_only = target.fetch(:historical_only, false)
      Row.new(
        label: display_label(component, historical_only: historical_only),
        source_label: component.label,
        category: component.category,
        hours: component.hours,
        rate: component.rate,
        current: component.amount.to_d.round(2),
        ytd: target.fetch(:ytd).round(2),
        historical_only: historical_only
      )
    end
  end

  # Each row's YTD prints only when the rows account for both printed totals and
  # every contributing paycheck can be attributed. Anything less returns nil and
  # the statement prints "—": a correction without stored rows, an opening
  # balance that was not itemized, stored rows that omit saved earnings, a pay
  # basis that cannot be established, or payroll fields whose identity would
  # merge into one row. Both the earnings statement and the check stub use it.
  def attributable_rows
    return @attributable_rows if defined?(@attributable_rows)

    @attributable_rows = itemized_rows
  end

  # Historical QuickBooks gross includes non-taxable reimbursements. They are
  # itemized under OTHER PAY, so subtract only that opening balance from the
  # displayed PAY total. Live non-taxable additions never enter gross wages.
  def pay_ytd_total(gross)
    (gross.to_d - (historical_balance&.non_taxable_pay || 0).to_d).round(2)
  end

  # The formatter also needs the evidence for YTD-only earning rows, while
  # retaining the original labels as this breakdown's financial grouping keys.
  def source_items
    ytd_source_items
  end

  private

  attr_reader :payroll_item, :employee, :pay_period, :company

  def itemized_rows
    return if SignedCorrectionEarnings.call(payroll_item)

    rows = call
    return unless rows.sum(0.to_d, &:current) == payroll_item.gross_pay.to_d.round(2)
    return unless rows.sum(0.to_d, &:ytd) == pay_ytd_total(@sources.totals[:gross])
    return if rows.any? { |row| row.current.nonzero? && row.ytd.zero? }
    return unless [ payroll_item, *ytd_source_items ].uniq.all? { |item| earnings_attributable?(item) }
    return unless payroll_field_rows_attributable?(rows)

    rows.reject { |row| row.current.zero? && row.ytd.zero? }.presence
  end

  def earnings_attributable?(item)
    stored = item.payroll_item_earnings.reject { |earning| earning.category.to_s == "non_taxable" }
    stored.any? ? stored_earnings_cover_item?(item, stored) : unstored_pay_basis_established?(item)
  end

  # Offsetting omissions can still foot, so compare each saved earning field too.
  def stored_earnings_cover_item?(item, stored)
    expected = {
      "bonus" => item.bonus,
      "tips" => item.reported_tips,
      "service_charge" => item.service_charge_wages,
      "other" => Array(item.custom_earnings).sum(0.to_d) { |entry| entry["amount"].to_d } +
        item.taxable_payroll_adjustments_total.to_d + item.taxable_payroll_field_entries_total.to_d
    }
    expected.all? do |category, amount|
      stored.select { |earning| earning.category.to_s == category }.sum(0.to_d) { |earning| earning.amount.to_d } == amount.to_d.round(2)
    end
  end

  # Reconstruction reads today's profile, so a contractor item needs a saved
  # basis that still agrees with it. A positive override is a fee, not hours.
  def unstored_pay_basis_established?(item)
    return false unless item.contractor? == employee.contractor?
    return true unless item.contractor?

    snapshot = item.calculation_context_snapshot.to_h["employee"]
    saved_pay_type = snapshot["contractor_pay_type"] if snapshot.is_a?(Hash)
    return false unless saved_pay_type.present? && saved_pay_type == employee.contractor_pay_type

    !employee.contractor_hourly? || !item.salary_override.to_d.positive?
  end

  # Field mirrors are saved by label alone. Print one only when its row holds
  # exactly that field's own amounts under a single label/treatment/category.
  def payroll_field_rows_attributable?(rows)
    entries = ytd_source_items.flat_map { |item| item.payroll_field_entries_for_calculation.select { |entry| entry.active? && entry.taxable_addition? } }
    entries.group_by(&:label).all? do |label, same_label|
      next false if same_label.map { |entry| [ entry.tax_treatment, entry.category ] }.uniq.many?

      total = same_label.sum(0.to_d) { |entry| entry.amount.to_d }.round(2)
      matching = rows.select { |row| row.source_label == label && row.category.to_s == "other" }
      matching.empty? ? total.zero? : matching.one? && matching.first.ytd == total
    end
  end

  def current_components
    @current_components ||= components_for(payroll_item)
      .reject { |component| non_taxable_component?(component) }
      .reject { |component| component.amount.to_d.zero? }
  end

  def live_components
    ytd_source_items.flat_map { |item| components_for(item).map { |component| contract_rate_component(item, component) } }
      .reject { |component| non_taxable_component?(component) }
  end

  # Contractors now earn one contract-rate row per rate. Earlier contractor OT
  # rows add to that row's YTD so a new statement lists no OT for a contractor.
  # A saved paycheck with its own OT rows still prints exactly what it paid.
  def contract_rate_component(item, component)
    return component unless contract_rate_statement? && item.employment_type == "contractor" && component.category.to_s == "overtime"

    label = component.label.to_s == "Contract OT" ? "Contract Labor" : component.label.to_s.delete_suffix(" OT")
    component.with(label: label, category: "regular")
  end

  def contract_rate_statement?
    return @contract_rate_statement if defined?(@contract_rate_statement)

    @contract_rate_statement = payroll_item.employment_type == "contractor" &&
      current_components.none? { |component| component.category.to_s == "overtime" }
  end

  def ytd_source_items
    @sources.items
  end

  def historical_components
    return [] unless historical_balance

    earnings = historical_balance.source_breakdown.to_h["earnings_breakdown"]
    return [] unless earnings.is_a?(Hash)

    earnings.filter_map do |label, amount|
      value = BigDecimal(amount.to_s, exception: false)
      next if label.to_s.blank? || value.nil? || !value.finite? || value.zero?

      component = Component.new(label: label.to_s, category: nil, hours: nil, rate: nil, amount: value)
      component unless non_taxable_component?(component)
    end
  end

  def historical_balance
    @sources.historical_balance
  end

  def components_for(item)
    earnings = item.earnings_in_entry_order
    return earnings.map { |earning| component_from_earning(earning) } if earnings.any?

    fallback_components(item)
  end

  def component_from_earning(earning)
    Component.new(
      label: earning.label,
      category: earning.category,
      hours: earning.hours,
      rate: earning.rate,
      amount: earning.amount.to_d
    )
  end

  # Older saved payroll items may predate PayrollItemEarning. Keep their check
  # stubs usable without changing or backfilling the saved payroll record.
  def fallback_components(item)
    components = []
    if item.hourly? || item.employee.contractor_hourly?
      add_fallback_wage_components(components, item)
    else
      excluded = item.bonus.to_d + item.reported_tips.to_d + item.service_charge_wages.to_d +
        custom_taxable_total(item) + item.taxable_payroll_field_entries_total.to_d
      base = item.gross_pay.to_d - excluded
      label = item.employee.contractor? ? "Contract Fee" : "Salary"
      category = item.employee.contractor? ? "contract_fee" : "salary"
      components << Component.new(label: label, category: category, hours: nil, rate: nil, amount: base) unless base.zero?
    end

    components << Component.new(label: "Bonus", category: "bonus", hours: nil, rate: nil, amount: item.bonus.to_d) if item.bonus.to_d.nonzero?
    components << Component.new(label: "Tips", category: "tips", hours: nil, rate: nil, amount: item.reported_tips.to_d) if item.reported_tips.to_d.nonzero?
    components << Component.new(label: "Service Charges", category: "service_charge", hours: nil, rate: nil, amount: item.service_charge_wages.to_d) if item.service_charge_wages.to_d.nonzero?
    append_custom_components(components, item)
    components
  end

  def add_fallback_wage_components(components, item)
    rate = item.pay_rate.to_d
    regular = item.hours_worked.to_d * rate
    overtime_rate = rate * 1.5.to_d
    overtime = item.overtime_hours.to_d * overtime_rate
    holiday = item.holiday_hours.to_d * rate
    pto = item.pto_hours.to_d * rate
    regular_label = fallback_regular_label(item.employee)

    components << Component.new(label: regular_label, category: "regular", hours: item.hours_worked, rate: rate, amount: regular) unless regular.zero?
    components << Component.new(label: "Overtime Pay", category: "overtime", hours: item.overtime_hours, rate: overtime_rate, amount: overtime) unless overtime.zero?
    components << Component.new(label: "Holiday Pay", category: "holiday", hours: item.holiday_hours, rate: rate, amount: holiday) unless holiday.zero?
    components << Component.new(label: "PTO Pay", category: "pto", hours: item.pto_hours, rate: rate, amount: pto) unless pto.zero?
  end

  def fallback_regular_label(employee)
    return "Contract Labor" if employee.contractor?

    label = @employee_copy ? employee.legacy_stub_regular_wage_label : employee.department&.name
    label.presence || "Regular Pay"
  end

  def append_custom_components(components, item)
    Array(item.custom_earnings).each do |entry|
      amount = entry["amount"].to_d
      components << Component.new(label: entry["label"].presence || "Other Earning", category: "other", hours: nil, rate: nil, amount: amount) unless amount.zero?
    end
    item.active_payroll_adjustments.each do |entry|
      next unless entry["treatment"] == "taxable_addition"

      amount = entry["amount"].to_d
      components << Component.new(label: entry["label"].presence || "Taxable Adjustment", category: "other", hours: nil, rate: nil, amount: amount) unless amount.zero?
    end
    item.payroll_item_field_entries.each do |entry|
      next unless entry.active? && entry.taxable_addition? && entry.amount.to_d.nonzero?

      components << Component.new(label: entry.label, category: "other", hours: nil, rate: nil, amount: entry.amount.to_d)
    end
  end

  def custom_taxable_total(item)
    Array(item.custom_earnings).sum(0.to_d) { |entry| entry["amount"].to_d } +
      item.taxable_payroll_adjustments_total.to_d
  end

  def add_to_target!(targets, component, semantic_fallback:, historical: false)
    target = target_for(targets, component, semantic_fallback: semantic_fallback)
    target ||= append_ytd_only_target!(targets, component, historical: historical)
    target[:ytd] += component.amount.to_d
  end

  def target_for(targets, component, semantic_fallback:)
    semantic = semantic_for(component.category, component.label)
    exact = targets.select { |target| target.fetch(:component).label.to_s == component.label.to_s }
    unless semantic_fallback
      same_category = exact.select do |target|
        target.fetch(:component).category.to_s == component.category.to_s
      end
      return same_category.first if same_category.one?

      return nil
    end

    return exact.first if exact.one?

    if exact.many?
      category_match = exact.select { |target| target.fetch(:component).category.to_s == component.category.to_s }
      return category_match.first if category_match.one?
      semantic_match = exact.select { |target| target.fetch(:semantic) == semantic }
      return semantic_match.first if semantic_match.one?
      return nil
    end

    return nil if semantic == :other

    semantic_matches = targets.select { |target| target.fetch(:semantic) == semantic }
    return semantic_matches.first if semantic_matches.one?

    nil
  end

  def append_ytd_only_target!(targets, component, historical: false)
    ytd_component = Component.new(
      label: component.label,
      category: component.category,
      hours: nil,
      rate: nil,
      amount: 0.to_d
    )
    target = {
      component: ytd_component,
      semantic: semantic_for(component.category, component.label),
      ytd: 0.to_d,
      historical_only: historical
    }
    targets << target
    target
  end

  def semantic_for(category, label)
    explicit = category.to_s
    return explicit.to_sym if explicit.in?(%w[salary bonus tips overtime holiday pto service_charge regular contract_fee])

    text = label.to_s
    return :non_taxable if text.match?(QuickbooksHistory::YtdBridgePlan::NON_TAXABLE_EARNING)
    return :tips if text.match?(QuickbooksHistory::YtdBridgePlan::TIPS) || text.match?(/\btips?\b/i)
    return :bonus if text.match?(/\bbonus\b/i)
    return :salary if text.match?(/\bsalary\b/i)
    return :overtime if text.match?(/\bovertime\b|\bot\b/i)
    return :holiday if text.match?(/\bholiday\b/i)
    return :pto if text.match?(/\bpto\b|\bvacation\b|\bsick\b/i)
    return :service_charge if text.match?(/\bservice\s+charges?\b/i)

    :other
  end

  def non_taxable_component?(component)
    component.category.to_s == "non_taxable" ||
      (component.category.blank? && semantic_for(component.category, component.label) == :non_taxable)
  end

  def display_label(component, historical_only: false)
    return "#{component.label.to_s.strip} (prior payroll)" if historical_only && component.label.to_s.strip.casecmp?("regular")

    case semantic_for(component.category, component.label)
    when :salary
      "Salary - #{employee.first_name&.first} #{employee.last_name}".strip
    when :tips
      "Paycheck Tips"
    else
      component.label
    end
  end
end
