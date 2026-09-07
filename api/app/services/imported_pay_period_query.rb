# frozen_string_literal: true

class ImportedPayPeriodQuery
  DEFAULT_PER_PAGE = 50
  MAX_PER_PAGE = 100
  Result = Data.define(:data, :meta)

  def initialize(company_id:, id:, params:, audience: :staff)
    @company_id = Integer(company_id)
    @id = Integer(id, exception: false)
    raise ActiveRecord::RecordNotFound, "Imported pay period not found" if @id.nil?
    @page = [ params.fetch(:page, 1).to_i, 1 ].max
    @per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
    @audience = audience.to_sym
    raise ArgumentError, "Unknown imported payroll audience" unless @audience.in?(%i[staff client])
  end

  def call
    period = HistoricalPayPeriod
      .joins(:historical_import_batch)
      .includes(historical_import_batch: :locked_by)
      .where(company_id: @company_id, period_type: "regular")
      .where(historical_import_batches: { company_id: @company_id, status: "locked" })
      .find(@id)

    scope = period.historical_paychecks.includes(:employee, :historical_worker, :historical_pay_period)
                  .order(Arel.sql("source_employee_name ASC, id ASC"))
    total_count = scope.count
    paychecks = scope.offset((@page - 1) * @per_page).limit(@per_page)

    Result.new(
      data: period_json(period, paychecks),
      meta: {
        current_page: @page,
        per_page: @per_page,
        total_count: total_count,
        total_pages: (total_count.to_f / @per_page).ceil
      }
    )
  end

  private

  def period_json(period, paychecks)
    batch = period.historical_import_batch
    source = {
      system: batch.source_system,
      label: "QuickBooks import",
      detail: period.source_label,
      locked: true,
      locked_at: batch.locked_at
    }
    if @audience == :staff
      source.merge!(
        import_batch_id: batch.id,
        importer_version: batch.importer_version,
        locked_by_name: batch.locked_by&.name
      )
    end

    {
      key: "imported:#{period.id}",
      record_type: "imported",
      id: period.id,
      company_id: period.company_id,
      start_date: period.start_date,
      end_date: period.end_date,
      pay_date: period.pay_date,
      status: "locked",
      run_purpose: "regular",
      includes_base_salary: true,
      correction_status: nil,
      notes: nil,
      compliance_warnings: [],
      employee_count: period.paycheck_count,
      total_gross: money(period.totals["gross_pay"]),
      total_net: money(period.totals["net_pay"]),
      source: source,
      capabilities: read_only_capabilities,
      paychecks: paychecks.map { |paycheck| paycheck_json(paycheck) }
    }
  end

  def read_only_capabilities
    {
      view: true,
      edit: false,
      delete: false,
      enter_hours: false,
      run: false,
      approve: false,
      commit: false
    }
  end

  def money(value)
    (BigDecimal(value.to_s, exception: false) || 0).to_f
  end

  def paycheck_json(paycheck)
    {
      id: paycheck.id,
      historical_pay_period_id: paycheck.historical_pay_period_id,
      historical_worker_id: paycheck.historical_worker_id,
      employee_id: paycheck.employee_id,
      employee_name: paycheck.employee&.full_name,
      source_employee_name: paycheck.source_employee_name,
      pay_date: paycheck.pay_date,
      period_start: paycheck.period_start,
      period_end: paycheck.period_end,
      period_type: paycheck.historical_pay_period.period_type,
      check_number: @audience == :staff ? paycheck.check_number : nil,
      payment_method: paycheck.payment_method,
      source_status: paycheck.source_status,
      reconciliation_status: paycheck.reconciliation_status,
      hours_total: paycheck.hours_total.to_s,
      gross_pay: paycheck.gross_pay.to_s,
      adjusted_gross: paycheck.adjusted_gross.to_s,
      pretax_deductions: paycheck.pretax_deductions.to_s,
      employee_taxes: paycheck.employee_taxes.to_s,
      federal_income_tax: paycheck.federal_income_tax.to_s,
      social_security_tax: paycheck.social_security_tax.to_s,
      medicare_tax: paycheck.medicare_tax.to_s,
      after_tax_deductions: paycheck.after_tax_deductions.to_s,
      net_pay: paycheck.net_pay.to_s,
      employer_taxes: paycheck.employer_taxes.to_s,
      employer_contributions: paycheck.employer_contributions.to_s,
      total_payroll_cost: paycheck.total_payroll_cost.to_s,
      hours_breakdown: paycheck.hours_breakdown,
      earnings_breakdown: paycheck.earnings_breakdown,
      pretax_deduction_breakdown: paycheck.pretax_deduction_breakdown,
      after_tax_deduction_breakdown: paycheck.after_tax_deduction_breakdown,
      employee_tax_breakdown: paycheck.employee_tax_breakdown,
      employer_tax_breakdown: paycheck.employer_tax_breakdown,
      employer_contribution_breakdown: paycheck.employer_contribution_breakdown
    }
  end
end
