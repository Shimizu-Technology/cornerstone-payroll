# frozen_string_literal: true

class UnifiedPayrollReporting
  SOURCE_STATEMENT = "QuickBooks source values remain authoritative locked snapshots and were not recalculated. Recorded ledger adjustments are shown separately and never rewrite the source."
  EMPLOYER_SOCIAL_SECURITY = /\A(?:SS|Social Security(?: Employer)?|Employer Social Security)\z/i
  OVERTIME_HOURS = /overtime|\bot\b|\bdouble[ -]?time\b/i
  REGULAR_HOURS = /\A(?!.*#{OVERTIME_HOURS})(?:regular|hourly)\b/i
  EMPLOYER_MEDICARE = /\A(?:Med|Medicare(?: Employer)?|Employer Medicare)\z/i
  AS_IMPORTED = "as_imported"
  BRIDGED = "historical_ytd_bridge"
  MIXED = "mixed"
  # The employee figures an applied opening balance carries, as pay stubs and
  # W-2GU read them. Hours, employer costs and deduction labels stay as imported.
  BRIDGE_FIGURES = {
    gross_pay: ->(balance) { balance.statement_gross_pay },
    non_taxable_pay: ->(balance) { balance.non_taxable_pay.to_d },
    withholding_tax: ->(balance) { balance.federal_income_tax.to_d },
    social_security_tax: ->(balance) { balance.social_security_tax.to_d },
    medicare_tax: ->(balance) { balance.medicare_tax.to_d },
    total_deductions: ->(balance) { balance.pretax_deductions.to_d + balance.employee_taxes.to_d + balance.after_tax_deductions.to_d },
    net_pay: ->(balance) { balance.net_pay.to_d }
  }.freeze

  def self.basis_label(basis)
    {
      BRIDGED => "Gross, non-taxable pay, income tax, Social Security, Medicare, deductions and net pay from the applied opening YTD balance; other figures as imported",
      AS_IMPORTED => "As imported",
      MIXED => "Partly from the applied opening YTD balance (gross, non-taxable pay, taxes, deductions and net pay), otherwise as imported"
    }.fetch(basis.to_s, basis.to_s.humanize)
  end

  def initialize(company_id:, period:)
    @company_id = Integer(company_id)
    @period = period
  end

  def historical_paychecks(employee_id: nil, limit: nil)
    scope = linked_historical_scope
    scope = scope.where(employee_id: employee_id) if employee_id
    scope = scope.reverse_chronological
    scope = scope.limit(limit) if limit
    scope.to_a
  end

  def unlinked_historical_paychecks
    historical_scope.where(employee_id: nil).to_a
  end

  def historical_adjustments(employee_id: nil)
    scope = locked_adjustment_scope.where(effective_pay_date: @period.range)
    scope = scope.where(historical_paychecks: { employee_id: employee_id }) if employee_id
    scope.chronological.to_a
  end

  def historical_tax_exclusion_note
    paychecks = historical_scope.pluck(:federal_income_tax, :gross_pay)
    adjustments = locked_adjustment_scope.where(effective_pay_date: @period.range)
      .pluck(:federal_income_tax, :gross_pay)
    amounts = paychecks + adjustments
    return if amounts.empty?

    fit = amounts.sum(0.to_d) { |withholding, _| withholding.to_d }
    wages = amounts.sum(0.to_d) { |_, gross_pay| gross_pay.to_d }
    note = "Imported QuickBooks/prior-provider payroll is not included."
    excluded = []
    excluded << "#{ActiveSupport::NumberHelper.number_to_currency(fit)} in #{PayrollLabels::INCOME_TAX}" unless fit.zero?
    excluded << "#{ActiveSupport::NumberHelper.number_to_currency(wages)} in gross wages" unless wages.zero?
    excluded.empty? ? note : "#{note} Excluded #{excluded.to_sentence}."
  end

  # The same eligible imported paychecks as historical_paychecks /
  # unlinked_historical_paychecks, but chosen because their pay period
  # overlaps the range rather than because they were paid in it (client
  # profitability's "work period" basis). linked: true, false or nil (both).
  def historical_paychecks_worked_in(linked: nil)
    scope = locked_historical_scope.where("historical_paychecks.period_start <= ? AND historical_paychecks.period_end >= ?",
                                          @period.end_date, @period.start_date)
    scope = scope.where.not(employee_id: nil) if linked == true
    scope = scope.where(employee_id: nil) if linked == false
    scope.to_a
  end

  # Imported adjustments whose paycheck's pay period overlaps the range.
  def historical_adjustments_worked_in
    locked_adjustment_scope.where("historical_paychecks.period_start <= ? AND historical_paychecks.period_end >= ?",
                                  @period.end_date, @period.start_date).chronological.to_a
  end

  def add_historical_to_employee_row(row, paychecks, adjustments = [])
    totals = historical_totals(paychecks, adjustments)
    row.merge(
      payroll_count: row.fetch(:payroll_count, 0).to_i + regular_period_count(paychecks),
      imported_payroll_count: regular_period_count(paychecks),
      imported_opening_summary_count: opening_summary_count(paychecks),
      total_hours: row.fetch(:total_hours, 0).to_d + totals[:total_hours],
      combined_hours: row.fetch(:combined_hours, 0).to_d + totals[:combined_hours],
      total_overtime_hours: row.fetch(:total_overtime_hours, 0).to_d + totals[:total_overtime_hours],
      gross_pay: (row.fetch(:gross_pay, 0).to_d + totals[:gross_pay]).to_f,
      non_taxable_additions_total: row.fetch(:non_taxable_additions_total, 0).to_d + totals[:non_taxable_pay],
      imported_basis: totals[:imported_basis],
      bridged_fields: totals[:bridged_fields] || [],
      bonus: (row.fetch(:bonus, 0).to_d + totals[:bonus]).to_f,
      straight_loan_deductions: row.fetch(:straight_loan_deductions, 0).to_f,
      installment_loan_payments: row.fetch(:installment_loan_payments, 0).to_f,
      historical_loan_deductions_unclassified: totals[:historical_loan_deductions_unclassified].to_f,
      health_insurance_deductions: (row.fetch(:health_insurance_deductions, 0).to_d + totals[:health_insurance_deductions]).to_f,
      source_labeled_after_tax_401k_in_pretax_bucket: totals[:source_labeled_after_tax_401k_in_pretax_bucket].to_f,
      employer_social_security_tax: (row.fetch(:employer_social_security_tax, 0).to_d + totals[:employer_social_security_tax]).to_f,
      employer_medicare_tax: (row.fetch(:employer_medicare_tax, 0).to_d + totals[:employer_medicare_tax]).to_f,
      other_employer_taxes: (row.fetch(:other_employer_taxes, 0).to_d + totals[:other_employer_taxes]).to_f,
      employer_taxes_total: (row.fetch(:employer_taxes_total, 0).to_d + totals[:employer_taxes_total]).to_f,
      employer_traditional_401k_match: (row.fetch(:employer_traditional_401k_match, 0).to_d + totals[:employer_traditional_401k_match]).to_f,
      employer_roth_401k_match: (row.fetch(:employer_roth_401k_match, 0).to_d + totals[:employer_roth_401k_match]).to_f,
      other_employer_contributions: (row.fetch(:other_employer_contributions, 0).to_d + totals[:other_employer_contributions]).to_f,
      employer_contributions: (row.fetch(:employer_contributions, 0).to_d + totals[:employer_contributions]).to_f,
      employer_taxes_and_contributions_total: (row.fetch(:employer_taxes_and_contributions_total, 0).to_d + totals[:employer_taxes_and_contributions_total]).to_f,
      employer_payroll_cost: (row.fetch(:employer_payroll_cost, 0).to_d + totals[:employer_payroll_cost]).to_f,
      withholding_tax: row.fetch(:withholding_tax, 0).to_d + totals[:withholding_tax],
      # Imported history does not separate W-4 4c from income tax.
      base_withholding_tax: row.fetch(:base_withholding_tax, 0).to_d + totals[:withholding_tax],
      additional_withholding: row.fetch(:additional_withholding, 0).to_d,
      social_security_tax: (row.fetch(:social_security_tax, 0).to_d + totals[:social_security_tax]).to_f,
      medicare_tax: (row.fetch(:medicare_tax, 0).to_d + totals[:medicare_tax]).to_f,
      retirement: (row.fetch(:retirement, 0).to_d + totals[:retirement]).to_f,
      roth_retirement: (row.fetch(:roth_retirement, 0).to_d + totals[:roth_retirement]).to_f,
      tips: (row.fetch(:tips, 0).to_d + totals[:tips]).to_f,
      tips_paid_out: (row.fetch(:tips_paid_out, 0).to_d + totals[:tips_paid_out]).to_f,
      total_deductions: (row.fetch(:total_deductions, 0).to_d + totals[:total_deductions]).to_f,
      net_pay: (row.fetch(:net_pay, 0).to_d + totals[:net_pay]).to_f
    )
  end

  def add_historical_to_company_totals(row, paychecks, adjustments = [], native_employee_ids:)
    totals = historical_totals(paychecks, adjustments)
    row.merge(
      total_hours: row.fetch(:total_hours, 0).to_d + totals[:total_hours],
      combined_hours: row.fetch(:combined_hours, 0).to_d + totals[:combined_hours],
      total_overtime_hours: row.fetch(:total_overtime_hours, 0).to_d + totals[:total_overtime_hours],
      gross_pay: (row.fetch(:gross_pay, 0).to_d + totals[:gross_pay]).to_f,
      non_taxable_additions_total: row.fetch(:non_taxable_additions_total, 0).to_d + totals[:non_taxable_pay],
      imported_basis: totals[:imported_basis],
      bridged_fields: totals[:bridged_fields] || [],
      bonus: (row.fetch(:bonus, 0).to_d + totals[:bonus]).to_f,
      straight_loan_deductions: row.fetch(:straight_loan_deductions, 0).to_f,
      installment_loan_payments: row.fetch(:installment_loan_payments, 0).to_f,
      historical_loan_deductions_unclassified: totals[:historical_loan_deductions_unclassified].to_f,
      health_insurance_deductions: (row.fetch(:health_insurance_deductions, 0).to_d + totals[:health_insurance_deductions]).to_f,
      source_labeled_after_tax_401k_in_pretax_bucket: totals[:source_labeled_after_tax_401k_in_pretax_bucket].to_f,
      employer_social_security_tax: (row.fetch(:employer_social_security_tax, 0).to_d + totals[:employer_social_security_tax]).to_f,
      employer_medicare_tax: (row.fetch(:employer_medicare_tax, 0).to_d + totals[:employer_medicare_tax]).to_f,
      other_employer_taxes: (row.fetch(:other_employer_taxes, 0).to_d + totals[:other_employer_taxes]).to_f,
      employer_taxes_total: (row.fetch(:employer_taxes_total, 0).to_d + totals[:employer_taxes_total]).to_f,
      employer_traditional_401k_match: (row.fetch(:employer_traditional_401k_match, 0).to_d + totals[:employer_traditional_401k_match]).to_f,
      employer_roth_401k_match: (row.fetch(:employer_roth_401k_match, 0).to_d + totals[:employer_roth_401k_match]).to_f,
      other_employer_contributions: (row.fetch(:other_employer_contributions, 0).to_d + totals[:other_employer_contributions]).to_f,
      employer_contributions: (row.fetch(:employer_contributions, 0).to_d + totals[:employer_contributions]).to_f,
      employer_taxes_and_contributions_total: (row.fetch(:employer_taxes_and_contributions_total, 0).to_d + totals[:employer_taxes_and_contributions_total]).to_f,
      employer_payroll_cost: (row.fetch(:employer_payroll_cost, 0).to_d + totals[:employer_payroll_cost]).to_f,
      withholding_tax: row.fetch(:withholding_tax, 0).to_d + totals[:withholding_tax],
      # Imported history does not separate W-4 4c from income tax.
      base_withholding_tax: row.fetch(:base_withholding_tax, 0).to_d + totals[:withholding_tax],
      additional_withholding: row.fetch(:additional_withholding, 0).to_d,
      social_security_tax: (row.fetch(:social_security_tax, 0).to_d + totals[:social_security_tax]).to_f,
      medicare_tax: (row.fetch(:medicare_tax, 0).to_d + totals[:medicare_tax]).to_f,
      retirement: (row.fetch(:retirement, 0).to_d + totals[:retirement]).to_f,
      roth_retirement: (row.fetch(:roth_retirement, 0).to_d + totals[:roth_retirement]).to_f,
      total_deductions: (row.fetch(:total_deductions, 0).to_d + totals[:total_deductions]).to_f,
      net_pay: (row.fetch(:net_pay, 0).to_d + totals[:net_pay]).to_f,
      payroll_count: row.fetch(:payroll_count, 0).to_i + regular_period_count(paychecks),
      employee_count: (native_employee_ids + paychecks.map(&:employee_id)).compact.uniq.length,
      imported_payroll_count: regular_period_count(paychecks),
      imported_opening_summary_count: opening_summary_count(paychecks)
    )
  end

  def historical_financial_totals(paychecks, adjustments = [])
    rows = paychecks + adjustments
    {
      hours: sum(rows, :hours_total),
      gross_pay: sum(rows, :gross_pay),
      non_taxable_pay: 0.to_d,
      adjusted_gross: sum(rows, :adjusted_gross),
      pretax_deductions: sum(rows, :pretax_deductions),
      employee_taxes: sum(rows, :employee_taxes),
      after_tax_deductions: sum(rows, :after_tax_deductions),
      net_pay: sum(rows, :net_pay),
      employer_taxes: sum(rows, :employer_taxes),
      employer_contributions: sum(rows, :employer_contributions),
      total_payroll_cost: sum(rows, :total_payroll_cost)
    }
  end

  # Keep the source's tax bucket and label intact. A label alone cannot prove
  # whether a historical loan was straight/installment or a 401(k) was post-tax.
  def historical_deduction_entries(paychecks, adjustments = [])
    [ [ paychecks, :paycheck ], [ adjustments, "historical_adjustment" ] ].flat_map do |rows, kind|
      rows.flat_map do |row|
        source = if kind == :paycheck
          row.historical_import_batch.source_system == "prior_provider" ? "prior_provider" : "quickbooks"
        else
          kind
        end
        employee_id = kind == :paycheck ? row.employee_id : row.historical_paycheck.employee_id
        %i[pretax_deduction_breakdown after_tax_deduction_breakdown].flat_map do |field|
          bucket = field == :pretax_deduction_breakdown ? "pre_tax_deduction" : "post_tax_deduction"
          Array(row.public_send(field)).filter_map do |raw|
            component = raw.to_h.with_indifferent_access
            label = component[:label].to_s.strip
            amount = BigDecimal(component[:amount].to_s, exception: false)
            next if label.blank? || amount.nil?

            { employee_id: employee_id, source: source, treatment: bucket, label: label, amount: amount }
          end
        end
      end
    end
  end

  def history_row(paycheck)
    totals = imported_totals([ paycheck ])
    {
      key: "imported:#{paycheck.id}",
      record_type: "imported",
      payroll_item_id: nil,
      pay_period_id: nil,
      historical_pay_period_id: paycheck.historical_pay_period_id,
      pay_date: paycheck.pay_date,
      period_description: paycheck.historical_pay_period.source_label,
      scheduled_hours: nil,
      hours_worked: recorded_hours_component(paycheck, REGULAR_HOURS)&.to_f,
      total_hours: paycheck.hours_total.to_f,
      overtime_hours: recorded_hours_component(paycheck, OVERTIME_HOURS)&.to_f,
      holiday_hours: nil,
      pto_hours: nil,
      reported_tips: totals[:tips].to_f,
      tips_paid_out: totals[:tips_paid_out].to_f,
      bonus: 0,
      custom_earnings_total: 0,
      custom_deductions_total: 0,
      # Gross as imported, which includes non-taxable reimbursements; the
      # period summary shows those under non-taxable additions instead.
      gross_pay: paycheck.gross_pay.to_f,
      non_taxable_pay: totals[:non_taxable_pay].to_f,
      withholding_tax: paycheck.federal_income_tax.to_f,
      additional_withholding: 0.0,
      total_income_tax_withheld: paycheck.federal_income_tax.to_f,
      social_security_tax: paycheck.social_security_tax.to_f,
      medicare_tax: paycheck.medicare_tax.to_f,
      total_deductions: totals[:total_deductions].to_f,
      net_pay: paycheck.net_pay.to_f,
      check_number: paycheck.check_number,
      payment_method: paycheck.payment_method,
      payroll_field_entries: [],
      payroll_field_totals: {},
      source: {
        system: paycheck.historical_import_batch.source_system,
        label: paycheck.historical_import_batch.source_system == "prior_provider" ? "Prior-provider history" : "QuickBooks import",
        locked: true
      },
      capabilities: { view: true, edit: false }
    }
  end

  def adjustment_history_row(adjustment)
    totals = imported_totals([], [ adjustment ])
    paycheck = adjustment.historical_paycheck
    {
      key: "historical_adjustment:#{adjustment.id}",
      record_type: "adjustment",
      payroll_item_id: nil,
      pay_period_id: nil,
      historical_pay_period_id: paycheck.historical_pay_period_id,
      historical_paycheck_id: paycheck.id,
      historical_adjustment_id: adjustment.id,
      pay_date: adjustment.effective_pay_date,
      period_description: "Historical #{adjustment.kind} · #{paycheck.historical_pay_period.source_label}",
      scheduled_hours: nil,
      hours_worked: nil,
      total_hours: adjustment.hours_total.to_f,
      overtime_hours: nil,
      holiday_hours: nil,
      pto_hours: nil,
      reported_tips: totals[:tips].to_f,
      tips_paid_out: 0,
      bonus: 0,
      custom_earnings_total: 0,
      custom_deductions_total: 0,
      gross_pay: adjustment.gross_pay.to_f,
      non_taxable_pay: totals[:non_taxable_pay].to_f,
      withholding_tax: adjustment.federal_income_tax.to_f,
      additional_withholding: 0.0,
      total_income_tax_withheld: adjustment.federal_income_tax.to_f,
      social_security_tax: adjustment.social_security_tax.to_f,
      medicare_tax: adjustment.medicare_tax.to_f,
      total_deductions: totals[:total_deductions].to_f,
      net_pay: adjustment.net_pay.to_f,
      check_number: nil,
      payment_method_label: PayrollPaymentLabel::ADJUSTMENT,
      reason: adjustment.reason,
      payroll_field_entries: [],
      payroll_field_totals: {},
      source: { system: "historical_adjustment", label: "Historical adjustment", locked: true },
      capabilities: { view: true, edit: false }
    }
  end

  # totals_basis is the imported_basis of the report's totals row, when the
  # report has one: whether imported figures come from the opening balance.
  def source_summary(native_items:, historical_paychecks:, historical_adjustments: [], excluded_unlinked_paychecks: [], totals_basis: nil)
    all_history = historical_paychecks + excluded_unlinked_paychecks + historical_adjustments.map(&:historical_paycheck)
    sources = all_history.map { |row| row.historical_import_batch.source_system }.uniq
    prior = historical_paychecks.select { |row| row.historical_import_batch.source_system == "prior_provider" }
    quickbooks = historical_paychecks - prior
    qb_unlinked = excluded_unlinked_paychecks.reject { |row| row.historical_import_batch.source_system == "prior_provider" }
    prior_unlinked = excluded_unlinked_paychecks - qb_unlinked
    native_employee_dates = native_items.map { |item| [ item.employee_id, item.pay_period.pay_date ] }.uniq
    historical_employee_dates = historical_paychecks.select { |paycheck| paycheck.historical_pay_period.period_type == "regular" }
      .map { |paycheck| [ paycheck.employee_id, paycheck.pay_date ] }.uniq
    overlapping_employee_dates = native_employee_dates & historical_employee_dates
    {
      mode: sources.empty? ? "committed_cornerstone_only" : (sources == [ "quickbooks_online" ] ? "locked_quickbooks_plus_committed_cornerstone" : "locked_historical_plus_committed_cornerstone"),
      source_statement: sources.include?("prior_provider") ? "Historical source values remain authoritative locked snapshots and were not recalculated. Prior-provider payments were already paid and create no new payment obligation." : SOURCE_STATEMENT,
      cornerstone: {
        payroll_count: native_items.map(&:pay_period_id).uniq.length,
        paycheck_count: native_items.length
      },
      quickbooks: historical_source_counts(quickbooks, qb_unlinked),
      **(sources.include?("prior_provider") ? { prior_provider: historical_source_counts(prior, prior_unlinked) } : {}),
      adjustments: {
        count: historical_adjustments.length,
        gross_pay_delta: sum(historical_adjustments, :gross_pay),
        net_pay_delta: sum(historical_adjustments, :net_pay)
      },
      source_overlap: {
        employee_pay_date_count: overlapping_employee_dates.length
      },
      historical_ytd_bridge: totals_basis ? bridge_summary.merge(totals_basis: totals_basis) : bridge_summary
    }
  end

  private

  def historical_source_counts(rows, excluded)
    {
      payroll_count: regular_period_count(rows), paycheck_count: regular_paycheck_count(rows),
      record_count: rows.length, opening_summary_count: opening_summary_count(rows),
      excluded_unlinked_paycheck_count: excluded.length,
      excluded_unlinked_gross_pay: sum(excluded, :gross_pay), excluded_unlinked_net_pay: sum(excluded, :net_pay)
    }
  end

  def historical_scope
    locked_historical_scope.where(pay_date: @period.range)
  end

  # Imported paychecks that count at all: this company, from a locked batch.
  def locked_historical_scope
    HistoricalPaycheck
      .joins(:historical_import_batch)
      .includes(:historical_import_batch, :historical_pay_period)
      .where(company_id: @company_id)
      .where(historical_import_batches: { company_id: @company_id, status: "locked" })
  end

  def locked_adjustment_scope
    HistoricalPaycheckAdjustment.joins(historical_paycheck: :historical_import_batch)
                                .includes(historical_paycheck: :historical_pay_period)
                                .where(company_id: @company_id)
                                .where(historical_import_batches: { company_id: @company_id, status: "locked" })
  end

  def linked_historical_scope
    historical_scope.where.not(employee_id: nil)
  end

  # Date-range totals for imported history. When the range covers an applied
  # opening balance's whole window (January 1 through its pay date) and every
  # imported row it was built from is here, that employee's figures come from
  # the balance: the same bridge-plus-native source W-2GU and the pay stubs
  # use. Anything else is labelled as imported.
  def historical_totals(paychecks, adjustments = [])
    totals = imported_totals(paychecks, adjustments)
    balances = covering_balances(paychecks, adjustments)
    return totals.merge(imported_basis: AS_IMPORTED) if balances.empty?

    covered = imported_totals(
      paychecks.select { |paycheck| balances.key?(bridge_key(paycheck)) },
      adjustments.select { |adjustment| balances.key?(bridge_key(adjustment)) }
    )
    BRIDGE_FIGURES.each do |field, figure|
      totals[field] = (totals[field] - covered[field] + balances.values.sum(0.to_d, &figure)).round(2)
    end
    complete = (paychecks + adjustments).all? { |row| balances.key?(bridge_key(row)) }
    # Only these fields come from the balance; every other figure (hours,
    # retirement, employer costs, deduction categories) stays as imported.
    totals.merge(imported_basis: complete ? BRIDGED : MIXED, bridged_fields: BRIDGE_FIGURES.keys.map(&:to_s))
  end

  # Every money figure stays BigDecimal; callers convert at the response.
  def imported_totals(paychecks, adjustments = [])
    rows = paychecks + adjustments
    non_taxable = rows.sum(0.to_d) { |row| non_taxable_pay(row) }
    employer_taxes_total = decimal_sum(rows, :employer_taxes)
    employer_social_security_tax = decimal_component_sum(rows, :employer_tax_breakdown, EMPLOYER_SOCIAL_SECURITY)
    employer_medicare_tax = decimal_component_sum(rows, :employer_tax_breakdown, EMPLOYER_MEDICARE)
    employer_contribution_totals = historical_employer_contribution_totals(rows)
    employer_contributions = decimal_sum(rows, :employer_contributions)
    {
      total_hours: paychecks.sum(0.to_d) { |paycheck| recorded_hours_component(paycheck, REGULAR_HOURS).to_d },
      combined_hours: rows.sum(0.to_d) { |row| row.hours_total.to_d },
      total_overtime_hours: paychecks.sum(0.to_d) { |paycheck| recorded_hours_component(paycheck, OVERTIME_HOURS).to_d },
      # Imported gross includes non-taxable reimbursements; like the pay stub,
      # reports show them as non-taxable additions instead.
      gross_pay: (rows.sum(0.to_d) { |row| row.gross_pay.to_d } - non_taxable).round(2),
      non_taxable_pay: non_taxable,
      bonus: decimal_component_sum(rows, :earnings_breakdown, /bonus/i),
      employer_social_security_tax: employer_social_security_tax,
      employer_medicare_tax: employer_medicare_tax,
      other_employer_taxes: (employer_taxes_total - employer_social_security_tax - employer_medicare_tax).round(2),
      employer_taxes_total: employer_taxes_total,
      employer_traditional_401k_match: employer_contribution_totals[:traditional_401k],
      employer_roth_401k_match: employer_contribution_totals[:roth_401k],
      other_employer_contributions: (employer_contributions - employer_contribution_totals[:traditional_401k] - employer_contribution_totals[:roth_401k]).round(2),
      employer_contributions: employer_contributions,
      employer_taxes_and_contributions_total: (employer_taxes_total + employer_contributions).round(2),
      employer_payroll_cost: decimal_sum(rows, :total_payroll_cost),
      withholding_tax: rows.sum(0.to_d) { |row| row.federal_income_tax.to_d },
      social_security_tax: decimal_sum(rows, :social_security_tax),
      medicare_tax: decimal_sum(rows, :medicare_tax),
      retirement: classified_deduction_sum(rows, "retirement", [ [ :pretax_deduction_breakdown, QuickbooksHistory::YtdBridgePlan::RETIREMENT_PRE_TAX ] ]),
      roth_retirement: classified_deduction_sum(rows, "roth_retirement", [ [ :after_tax_deduction_breakdown, QuickbooksHistory::YtdBridgePlan::RETIREMENT_ROTH ] ]),
      historical_loan_deductions_unclassified: classified_deduction_sum(rows, "loans", [ [ :pretax_deduction_breakdown, QuickbooksHistory::YtdBridgePlan::LOAN ],
        [ :after_tax_deduction_breakdown, QuickbooksHistory::YtdBridgePlan::LOAN ] ]),
      health_insurance_deductions: classified_deduction_sum(rows, "insurance", [ [ :pretax_deduction_breakdown, /\AHealth Insurance\z/i ],
        [ :after_tax_deduction_breakdown, /\AHealth Insurance\z/i ] ]),
      source_labeled_after_tax_401k_in_pretax_bucket: decimal_component_sum(rows, :pretax_deduction_breakdown, /\A401\(k\) After Tax\z/i),
      tips: rows.sum(0.to_d) { |row| verified_history_amount(row, "reported_tips") || decimal_component_sum([ row ], :earnings_breakdown, QuickbooksHistory::YtdBridgePlan::TIPS) }.round(2),
      # QuickBooks does not distinguish paid-out tips; the existing-roster lane
      # requires the provider's explicit verified value.
      tips_paid_out: rows.sum(0.to_d) { |row| verified_history_amount(row, "tips_paid_out") || 0.to_d }.round(2),
      total_deductions: rows.sum(0.to_d) { |paycheck| paycheck.pretax_deductions.to_d + paycheck.employee_taxes.to_d + paycheck.after_tax_deductions.to_d }.round(2),
      net_pay: decimal_sum(rows, :net_pay)
    }
  end

  # The opening balance an imported row was carried into, keyed as
  # covering_balances keys them.
  def bridge_key(row)
    paycheck = row.is_a?(HistoricalPaycheckAdjustment) ? row.historical_paycheck : row
    date = row.is_a?(HistoricalPaycheckAdjustment) ? row.effective_pay_date : row.pay_date
    [ paycheck.historical_import_batch_id, paycheck.employee_id, date.year ]
  end

  def covering_balances(paychecks, adjustments)
    keys = (paychecks + adjustments).map { |row| bridge_key(row) }.uniq
    keys.filter_map do |key|
      balance = range_balances[key]
      next unless balance

      sources = bridge_sources(key)
      present_paychecks = paychecks.select { |paycheck| bridge_key(paycheck) == key }.map(&:id).sort
      present_adjustments = adjustments.select { |adjustment| bridge_key(adjustment) == key }.map(&:id).sort
      [ key, balance ] if present_paychecks == sources.fetch(:paychecks) && present_adjustments == sources.fetch(:adjustments)
    end.to_h
  end

  # Applied balances whose whole window this range covers, from the latest
  # applied bridge of each locked import whose adjustments it still reflects
  # (HistoricalPayrollFilingSource's bridge for W-2GU).
  def range_balances
    @range_balances ||= begin
      batches = HistoricalImportBatch.where(company_id: @company_id, status: "locked").includes(:latest_applied_historical_ytd_bridge).to_a
      digests = HistoricalPayroll::Ledger.adjustment_digests(batches)
      bridges = batches.filter_map do |batch|
        bridge = batch.latest_applied_historical_ytd_bridge
        bridge if bridge && bridge.preview_summary.to_h["adjustment_digest"].to_s == digests.fetch(batch.id)
      end
      years = @period.start_date.year..@period.end_date.year
      HistoricalEmployeeYtdBalance.includes(:historical_ytd_bridge)
        .where(company_id: @company_id, historical_ytd_bridge_id: bridges.map(&:id), tax_year: years)
        .select { |balance| @period.range.cover?(Date.new(balance.tax_year, 1, 1)) && @period.range.cover?(balance.through_pay_date) }
        .index_by { |balance| [ balance.historical_ytd_bridge.historical_import_batch_id, balance.employee_id, balance.tax_year ] }
    end
  end

  # Every imported row each covering balance was built from, for all of the
  # range's balances in two queries, keyed as range_balances is.
  def bridge_sources(key)
    @bridge_sources ||= begin
      keys = range_balances.keys
      sources = keys.index_with { { paychecks: [], adjustments: [] } }
      if keys.any?
        batch_ids = keys.map(&:first).uniq
        employee_ids = keys.map(&:second).uniq
        years = keys.map(&:third)
        dates = Date.new(years.min, 1, 1)..Date.new(years.max, 12, 31)
        HistoricalPaycheck.where(historical_import_batch_id: batch_ids, employee_id: employee_ids, pay_date: dates)
          .order(:id).pluck(:id, :historical_import_batch_id, :employee_id, :pay_date).each do |id, batch_id, employee_id, pay_date|
            sources[[ batch_id, employee_id, pay_date.year ]]&.fetch(:paychecks)&.push(id)
          end
        HistoricalPaycheckAdjustment.joins(:historical_paycheck)
          .where(historical_paychecks: { historical_import_batch_id: batch_ids, employee_id: employee_ids }, effective_pay_date: dates)
          .order(:id).pluck(:id, "historical_paychecks.historical_import_batch_id", "historical_paychecks.employee_id", :effective_pay_date)
          .each do |id, batch_id, employee_id, pay_date|
            sources[[ batch_id, employee_id, pay_date.year ]]&.fetch(:adjustments)&.push(id)
          end
      end
      sources
    end
    @bridge_sources.fetch(key)
  end

  def non_taxable_pay(row)
    verified = row.is_a?(HistoricalPaycheck) && row.historical_import_batch.source_system == "prior_provider" &&
      row.source_metadata.to_h.dig("verified_amounts", "non_taxable_pay")
    return verified.to_d if verified

    matching_component_amounts(row.earnings_breakdown, QuickbooksHistory::YtdBridgePlan::NON_TAXABLE_EARNING).sum(0.to_d).round(2)
  end

  def verified_history_amount(row, field)
    return unless row.is_a?(HistoricalPaycheck) && row.historical_import_batch.source_system == "prior_provider"

    row.source_metadata.fetch("verified_amounts").fetch(field).to_d
  end

  def classified_deduction_sum(rows, field, components)
    rows.sum(0.to_d) do |row|
      verified_history_amount(row, field) || components.sum(0.to_d) { |bucket, pattern| decimal_component_sum([ row ], bucket, pattern) }
    end.round(2)
  end

  def sum(paychecks, field)
    paychecks.sum(0.to_d) { |paycheck| paycheck.public_send(field).to_d }.to_f
  end

  def component_sum(paychecks, field, pattern)
    paychecks.sum(0.to_d) { |paycheck| matching_component_amounts(paycheck.public_send(field), pattern).sum(0.to_d) }.to_f
  end

  def decimal_sum(rows, field)
    rows.sum(0.to_d) { |row| row.public_send(field).to_d }.round(2)
  end

  def decimal_component_sum(rows, field, pattern)
    rows.sum(0.to_d) { |row| matching_component_amounts(row.public_send(field), pattern).sum(0.to_d) }.round(2)
  end

  def recorded_hours_component(paycheck, pattern)
    amounts = matching_component_amounts(paycheck.hours_breakdown, pattern)
    amounts.sum(0.to_d) if amounts.any?
  end

  def matching_component_amounts(components, pattern)
    Array(components).filter_map do |entry|
      component = entry.to_h.with_indifferent_access
      BigDecimal(component[:amount].to_s, exception: false) if component[:label].to_s.squish.match?(pattern)
    end
  end

  def historical_employer_contribution_totals(rows)
    totals = { traditional_401k: 0.to_d, roth_401k: 0.to_d }
    rows.each do |row|
      Array(row.employer_contribution_breakdown).each do |entry|
        component = entry.to_h.with_indifferent_access
        amount = BigDecimal(component[:amount].to_s, exception: false) || 0.to_d
        group = PayrollReportingGroups.infer_retirement_group(
          label: component[:label],
          tax_treatment: "employer_contribution"
        )
        totals[:traditional_401k] += amount if group == PayrollReportingGroups::GROUP_401K_PRE_TAX
        totals[:roth_401k] += amount if group == PayrollReportingGroups::GROUP_401K_AFTER_TAX
      end
    end
    totals.transform_values { |amount| amount.round(2) }
  end

  def regular_period_count(paychecks)
    paychecks.filter_map do |paycheck|
      paycheck.historical_pay_period_id if paycheck.historical_pay_period.period_type == "regular"
    end.uniq.length
  end

  def opening_summary_count(paychecks)
    paychecks.count { |paycheck| paycheck.historical_pay_period.period_type == "opening_summary" }
  end

  def regular_paycheck_count(paychecks)
    paychecks.count { |paycheck| paycheck.historical_pay_period.period_type == "regular" }
  end

  def bridge_summary
    balances = HistoricalEmployeeYtdBalance
      .joins(:historical_ytd_bridge)
      .where(company_id: @company_id, tax_year: @period.start_date.year..@period.end_date.year)
      .where(historical_ytd_bridges: { status: "applied" })
    {
      applied: balances.exists?,
      tax_years: balances.distinct.order(:tax_year).pluck(:tax_year),
      through_pay_date: balances.maximum(:through_pay_date),
      through_period_end: balances.maximum(:through_period_end)
    }
  end
end
