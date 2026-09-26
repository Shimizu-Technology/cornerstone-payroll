# frozen_string_literal: true

# Builds the earnings rows shown on a check stub and carries each row's YTD
# amount across the locked QuickBooks opening balance and reportable
# Cornerstone payroll. Historical source labels are matched exactly first and
# only fall back to a semantic bucket when there is a single unambiguous
# current row for that bucket.
class PayrollEarningsYtdBreakdown
  Row = Data.define(:label, :source_label, :category, :hours, :rate, :current, :ytd)
  Component = Data.define(:label, :category, :hours, :rate, :amount)

  def initialize(payroll_item)
    @payroll_item = payroll_item
    @employee = payroll_item.employee
    @pay_period = payroll_item.pay_period
    @company = payroll_item.company
  end

  def call
    targets = current_components.map do |component|
      {
        component: component,
        semantic: semantic_for(component.category, component.label),
        ytd: 0.to_d
      }
    end

    live_components.each { |component| add_to_target!(targets, component, semantic_fallback: false) }
    historical_components.each { |component| add_to_target!(targets, component, semantic_fallback: true) }

    targets.map do |target|
      component = target.fetch(:component)
      Row.new(
        label: display_label(component),
        source_label: component.label,
        category: component.category,
        hours: component.hours,
        rate: component.rate,
        current: component.amount.to_d.round(2),
        ytd: target.fetch(:ytd).round(2)
      )
    end
  end

  # Historical QuickBooks gross includes non-taxable reimbursements. They are
  # itemized under OTHER PAY, so subtract only that opening balance from the
  # displayed PAY total. Live non-taxable additions never enter gross wages.
  def pay_ytd_total(gross)
    (gross.to_d - (historical_balance&.non_taxable_pay || 0).to_d).round(2)
  end

  private

  attr_reader :payroll_item, :employee, :pay_period, :company

  def current_components
    @current_components ||= components_for(payroll_item)
      .reject { |component| non_taxable_component?(component) }
      .reject { |component| component.amount.to_d.zero? }
  end

  def live_components
    ytd_source_items.flat_map { |item| components_for(item) }
      .reject { |component| non_taxable_component?(component) }
  end

  def ytd_source_items
    @ytd_source_items ||= begin
      pay_date = pay_period.pay_date || Date.current
      prior_periods = PayPeriod.reportable_for_company(company)
        .where(pay_date: Date.new(pay_date.year, 1, 1)..pay_date)
        .where(
          "pay_date < :pay_date OR (pay_date = :pay_date AND id < :period_id)",
          pay_date: pay_date,
          period_id: pay_period.id
        )
      prior_periods = prior_periods.where("pay_date > ?", historical_cutoff) if historical_cutoff
      items = employee.payroll_items.not_voided
        .where(company_id: company.id, pay_period_id: prior_periods.select(:id))
        .includes(:payroll_item_earnings, :payroll_item_field_entries)
        .to_a

      if !payroll_item.voided? &&
          pay_period.correction_status.in?([ nil, "correction" ]) &&
          (historical_cutoff.nil? || pay_date > historical_cutoff)
        items << payroll_item
      end
      items
    end
  end

  def historical_components
    return [] unless historical_balance

    historical_balance.source_breakdown.to_h.fetch("earnings_breakdown", {}).filter_map do |label, amount|
      value = BigDecimal(amount.to_s, exception: false)
      next if label.to_s.blank? || value.nil? || value.zero?

      component = Component.new(label: label.to_s, category: nil, hours: nil, rate: nil, amount: value)
      component unless non_taxable_component?(component)
    end
  end

  def historical_balance
    @historical_balance ||= HistoricalEmployeeYtdBalance
      .joins(:historical_ytd_bridge)
      .where(
        company_id: company.id,
        employee_id: employee.id,
        tax_year: (pay_period.pay_date || Date.current).year,
        historical_ytd_bridges: { status: "applied" }
      )
      .where("historical_employee_ytd_balances.through_pay_date <= ?", pay_period.pay_date || Date.current)
      .order(
        through_pay_date: :desc,
        "historical_ytd_bridges.applied_at" => :desc,
        "historical_ytd_bridges.id" => :desc,
        id: :desc
      )
      .first
  end

  def historical_cutoff
    historical_balance&.through_pay_date
  end

  def components_for(item)
    earnings = item.payroll_item_earnings.to_a
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
    regular_label = item.employee.contractor? ? "Contract Labor" : item.employee.department&.name.presence || "Regular Pay"

    components << Component.new(label: regular_label, category: "regular", hours: item.hours_worked, rate: rate, amount: regular) unless regular.zero?
    components << Component.new(label: "Overtime Pay", category: "overtime", hours: item.overtime_hours, rate: overtime_rate, amount: overtime) unless overtime.zero?
    components << Component.new(label: "Holiday Pay", category: "holiday", hours: item.holiday_hours, rate: rate, amount: holiday) unless holiday.zero?
    components << Component.new(label: "PTO Pay", category: "pto", hours: item.pto_hours, rate: rate, amount: pto) unless pto.zero?
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

  def add_to_target!(targets, component, semantic_fallback:)
    target = target_for(targets, component, semantic_fallback: semantic_fallback)
    target ||= append_ytd_only_target!(targets, component)
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

  def append_ytd_only_target!(targets, component)
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
      ytd: 0.to_d
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

  def display_label(component)
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
