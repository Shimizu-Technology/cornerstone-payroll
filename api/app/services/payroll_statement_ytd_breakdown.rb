# frozen_string_literal: true

# Builds the non-wage rows shown on checks and pay stubs. Every row combines
# the locked QuickBooks opening balance with reportable Cornerstone payroll
# after the historical cutoff, so the rendered lines and their totals share a
# single source of truth.
class PayrollStatementYtdBreakdown
  Row = Data.define(:label, :current, :ytd, :semantic)
  Component = Data.define(:label, :amount, :semantic)

  KINDS = %i[deduction other_pay employer_contribution].freeze
  CHILD_SUPPORT = /child\s*support|remittance\s*id|case\s*no\.?|\bcs\d/i
  GARNISHMENT = /garnish/i
  ALLOTMENT = /allotment/i
  RENT = /\brent\b/i
  REIMBURSEMENT = /reimb(?:ursement|ursem)?/i
  AUTO_LOAN_REIMBURSEMENT = /\bauto\s+loan\s+reimb(?:ursement|ursem)?/i
  GENERIC_REIMBURSEMENT = /\Areimb(?:ursement|ursem)?\z/i

  def initialize(payroll_item)
    @payroll_item = payroll_item
    @employee = payroll_item.employee
    @pay_period = payroll_item.pay_period
    @company = payroll_item.company
  end

  def deductions
    rows_for(:deduction)
  end

  def other_pay
    rows_for(:other_pay)
  end

  def employer_contributions
    rows_for(:employer_contribution)
  end

  private

  attr_reader :payroll_item, :employee, :pay_period, :company

  def rows_for(kind)
    raise ArgumentError, "Unknown statement component kind: #{kind}" unless KINDS.include?(kind)

    @rows_by_kind ||= {}
    @rows_by_kind[kind] ||= begin
      targets = current_components(kind).map do |component|
        { component: component, semantic: component.semantic, ytd: 0.to_d }
      end

      live_components(kind).each do |component|
        add_to_target!(targets, component, semantic_fallback: false)
      end
      historical_components(kind).each do |component|
        add_to_target!(targets, component, semantic_fallback: true)
      end

      targets.map do |target|
        component = target.fetch(:component)
        Row.new(
          label: display_label(component, kind),
          current: component.amount.to_d.round(2),
          ytd: target.fetch(:ytd).round(2),
          semantic: target.fetch(:semantic)
        )
      end
    end
  end

  def current_components(kind)
    @current_components ||= {}
    @current_components[kind] ||= components_for(payroll_item, kind)
  end

  def live_components(kind)
    @live_components ||= {}
    @live_components[kind] ||= ytd_source_items.flat_map { |item| components_for(item, kind) }
  end

  def components_for(item, kind)
    report_data = report_data_for(item.pay_period)
    components = case kind
    when :deduction
      report_data.deduction_contribution_entries_for_item(item).filter_map do |entry|
        next unless entry.bucket.in?(%w[pre_tax post_tax]) && entry.employee_amount.to_d.positive?

        Component.new(
          label: statement_label_for_entry(entry),
          amount: entry.employee_amount.to_d,
          semantic: semantic_for_deduction_entry(entry)
        )
      end
    when :other_pay
      report_data.other_pay_lines_for(item).filter_map do |line|
        next unless line.amount.to_d.positive?

        Component.new(label: line.label, amount: line.amount.to_d, semantic: semantic_for_other_pay(line.label))
      end
    when :employer_contribution
      report_data.deduction_contribution_entries_for_item(item).filter_map do |entry|
        next unless entry.company_amount.to_d.positive?

        Component.new(
          label: statement_label_for_entry(entry),
          amount: entry.company_amount.to_d,
          semantic: semantic_for_employer_contribution(entry)
        )
      end
    end

    aggregate_components(components)
  end

  def report_data_for(period)
    @report_data_by_period_id ||= {}
    @report_data_by_period_id[period.id] ||= QuickbooksPayrollReportData.new(period)
  end

  def aggregate_components(components)
    components.group_by { |component| [ normalized_label(component.label), component.semantic ] }.map do |(_key, semantic), grouped|
      Component.new(
        label: grouped.first.label,
        amount: grouped.sum(0.to_d) { |component| component.amount.to_d },
        semantic: semantic
      )
    end
  end

  def historical_components(kind)
    return [] unless historical_balance

    case kind
    when :deduction
      historical_deduction_components
    when :other_pay
      historical_breakdown("earnings_breakdown").filter_map do |label, amount|
        next unless label.match?(QuickbooksHistory::YtdBridgePlan::NON_TAXABLE_EARNING)

        component(label, amount, semantic_for_other_pay(label))
      end
    when :employer_contribution
      historical_breakdown("employer_contribution_breakdown").filter_map do |label, amount|
        component(label, amount, semantic_for_label(label, bucket: :employer_contribution))
      end
    end
  end

  def historical_deduction_components
    components = []
    {
      "pretax_deduction_breakdown" => :pre_tax,
      "after_tax_deduction_breakdown" => :post_tax
    }.each do |field, bucket|
      historical_breakdown(field).each do |label, amount|
        value = component(label, amount, semantic_for_label(label, bucket: bucket))
        components << value if value
      end
    end

    tips_paid_out = historical_balance.tips_paid_out.to_d
    unless tips_paid_out.zero? || components.any? { |entry| entry.semantic == :tips_paid_out }
      components << Component.new(label: "Tips Paid Out", amount: tips_paid_out, semantic: :tips_paid_out)
    end
    aggregate_components(components)
  end

  def historical_breakdown(field)
    historical_balance.source_breakdown.to_h.fetch(field, {}).to_h
  end

  def component(label, amount, semantic)
    value = BigDecimal(amount.to_s, exception: false)
    return if label.to_s.blank? || value.nil? || value.zero?

    Component.new(label: label.to_s, amount: value, semantic: semantic)
  end

  def add_to_target!(targets, component, semantic_fallback:)
    target = target_for(targets, component, semantic_fallback: semantic_fallback)
    target ||= append_ytd_only_target!(targets, component)
    target[:ytd] += component.amount.to_d
  end

  def target_for(targets, component, semantic_fallback:)
    exact = targets.select do |target|
      normalized_label(target.fetch(:component).label) == normalized_label(component.label)
    end
    semantic_exact = exact.select { |target| target.fetch(:semantic) == component.semantic }
    return semantic_exact.first if semantic_exact.one?
    return exact.first if exact.one?
    return nil unless semantic_fallback && component.semantic != :other

    semantic_matches = targets.select { |target| target.fetch(:semantic) == component.semantic }
    return semantic_matches.first if semantic_matches.one?

    legacy_other_pay_target(targets, component)
  end

  def legacy_other_pay_target(targets, component)
    return unless component.semantic == :reimbursement && component.label.match?(GENERIC_REIMBURSEMENT)

    # QuickBooks can export an employee allotment under the generic label
    # "Reimb" while the reviewed current field has an explicit allotment name.
    # Bridge that rename only when one allotment target exists and the locked
    # historical total is an exact repetition of its current recurring amount.
    candidates = targets.select do |target|
      target.fetch(:semantic) == :allotment &&
        repeated_recurring_amount?(component.amount, target.fetch(:component).amount)
    end
    candidates.one? ? candidates.first : nil
  end

  def repeated_recurring_amount?(historical_amount, current_amount)
    historical = historical_amount.to_d
    current = current_amount.to_d
    historical.positive? && current.positive? &&
      historical >= current && (historical % current).zero?
  end

  def append_ytd_only_target!(targets, component)
    target = {
      component: Component.new(label: component.label, amount: 0.to_d, semantic: component.semantic),
      semantic: component.semantic,
      ytd: 0.to_d
    }
    targets << target
    target
  end

  def semantic_for_deduction_entry(entry)
    group = PayrollReportingGroups.normalize(entry.reporting_group)
    return group.to_sym if group
    return :tips_paid_out if entry.source == "tips_paid_out"

    semantic_for_label(entry.description, type: entry.type, bucket: entry.bucket)
  end

  def semantic_for_employer_contribution(entry)
    group = PayrollReportingGroups.normalize(entry.reporting_group)
    group ? group.to_sym : semantic_for_label(entry.description, type: entry.type, bucket: :employer_contribution)
  end

  def statement_label_for_entry(entry)
    return entry.description unless PayrollReportingGroups.normalize(entry.reporting_group) == PayrollReportingGroups::GROUP_RETIREMENT_OTHER

    amount = entry.employee_amount.to_d.nonzero? ? entry.employee_amount.to_d : entry.company_amount.to_d
    labels = case entry.source
    when "deduction"
      entry.item.payroll_item_deductions.filter_map do |deduction|
        next unless deduction.amount.to_d == amount
        next unless PayrollReportingGroups.normalize(deduction.reporting_group) == PayrollReportingGroups::GROUP_RETIREMENT_OTHER

        deduction.label
      end
    when "payroll_field"
      entry.item.payroll_item_field_entries.filter_map do |field|
        next unless field.active? && field.amount.to_d == amount
        next unless PayrollReportingGroups.normalize(field.reporting_group) == PayrollReportingGroups::GROUP_RETIREMENT_OTHER

        field.label
      end
    else
      []
    end

    labels.uniq.one? ? labels.first : entry.description
  end

  def semantic_for_label(label, type: nil, bucket: nil)
    text = [ label, type ].compact.join(" ")
    retirement_group = PayrollReportingGroups.infer_retirement_group(
      label: label,
      tax_treatment: bucket == :post_tax || bucket == "post_tax" ? "post_tax_deduction" : nil,
      deduction_category: bucket.to_s
    )
    return retirement_group.to_sym if retirement_group
    return :insurance if text.match?(QuickbooksHistory::YtdBridgePlan::INSURANCE)
    return :child_support if text.match?(CHILD_SUPPORT)
    return :garnishment if text.match?(GARNISHMENT)
    return :loan if text.match?(QuickbooksHistory::YtdBridgePlan::LOAN)
    return :tips_paid_out if text.match?(/tips?\s+paid\s+out/i)

    :other
  end

  def semantic_for_other_pay(label)
    text = label.to_s
    return :allotment if text.match?(ALLOTMENT)
    return :rent if text.match?(RENT)
    return :auto_loan_reimbursement if text.match?(AUTO_LOAN_REIMBURSEMENT)
    return :reimbursement if text.match?(REIMBURSEMENT)

    :other
  end

  def display_label(component, kind)
    return component.label unless kind == :deduction

    case component.semantic
    when PayrollReportingGroups::GROUP_401K_PRE_TAX.to_sym
      "401(k) Pre-Tax"
    when PayrollReportingGroups::GROUP_401K_AFTER_TAX.to_sym
      "Roth 401(k)"
    else
      component.label
    end
  end

  def normalized_label(label)
    label.to_s.squish.downcase
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
        .includes(
          :payroll_item_earnings,
          { pay_period: :company },
          { payroll_item_field_entries: :payroll_field_definition },
          payroll_item_deductions: :deduction_type
        )
        .to_a

      if !payroll_item.voided? &&
          pay_period.correction_status.in?([ nil, "correction" ]) &&
          (historical_cutoff.nil? || pay_date > historical_cutoff)
        items << payroll_item
      end
      items
    end
  end
end
