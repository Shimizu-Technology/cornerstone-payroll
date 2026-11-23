# frozen_string_literal: true

module PayrollHistoryReview
  # Shared source selection for the conservative proof and the review checklist.
  class Sources
    PERIOD_DATES = %i[start_date end_date pay_date].freeze

    def initialize(company:, year:, employee_ids: nil, excluding_pay_period_id: nil)
      @company, @year, @employee_ids, @excluding_pay_period_id = company, year, employee_ids, excluding_pay_period_id
    end

    def candidates
      items.includes(:pay_period, :legacy_disposition, :fica_basis_proof).order(:id)
    end

    def voided_periods
      scope = committed_periods.voided.where(id: items.select(:pay_period_id))
      scope.includes(payroll_items: [ :check_events, :check_reconciliation_events, :direct_deposit_payment_confirmation, :legacy_disposition ])
    end

    def replacements_for(voids)
      return {} if voids.empty?

      runs = PayPeriod.where(company: @company).where("correction_status IS DISTINCT FROM 'voided'")
      ids = voids.map(&:id)
      linked = runs.where(corrects_pay_period_id: ids).or(runs.where(source_pay_period_id: ids))
        .or(runs.where(id: voids.filter_map(&:superseded_by_id)))
      same_dates = runs.where(status: "committed").where(PERIOD_DATES => voids.map { |period| period_dates(period) }.uniq)
      replacements = linked.or(same_dates).includes(:payroll_items).order(:id).to_a
      by_id = replacements.index_by(&:id)
      by_correction = replacements.group_by(&:corrects_pay_period_id)
      by_source = replacements.group_by(&:source_pay_period_id)
      by_dates = replacements.select(&:committed?).group_by { |period| period_dates(period) }
      voids.to_h do |period|
        candidates = by_correction.fetch(period.id, []) | by_source.fetch(period.id, []) |
          Array(by_id[period.superseded_by_id]) | by_dates.fetch(period_dates(period), [])
        [ period.id, candidates.sort_by(&:id) ]
      end
    end

    def reversals
      reversed_items.includes(:pay_period, :employee)
    end

    def legacy_dispositions
      disposed_items.includes(:pay_period, :employee, :legacy_disposition)
    end

    def unverified_legacy
      legacy_missing_fica.left_joins(:fica_basis_proof)
        .where("jsonb_typeof(payroll_items.tax_rule_snapshot -> 'annual_fica_context' -> 'fingerprint') IS DISTINCT FROM 'string' OR " \
          "payroll_items.tax_rule_snapshot -> 'annual_fica_context' ->> 'fingerprint' = ''")
        .where(payroll_item_fica_basis_proofs: { id: nil }).order(:id)
    end

    def proof_backed_legacy
      legacy_missing_fica.joins(:fica_basis_proof)
    end

    def w2_missing_bases
      scope = YearEnd::W2PayrollItems.scope(@company.id, @year).where(YearEnd::W2PayrollItems::MISSING_TAX_BASE)
      scope = scope.where(employee_id: @employee_ids) if @employee_ids
      @excluding_pay_period_id ? scope.where.not(pay_period_id: @excluding_pay_period_id) : scope
    end

    def imported_paychecks
      scope = HistoricalPaycheck.where(company: @company, pay_date: year_range)
      scope = scope.where(employee_id: [ nil, *@employee_ids ]) if @employee_ids
      scope.includes(:employee, :historical_import_batch, :historical_worker, :historical_pay_period,
        :historical_paycheck_adjustments, :fica_basis_proof).order(:id)
    end

    def disputed_import_batch_ids(rules)
      batches_by_employee = HistoricalPaycheck.where(company: @company, pay_date: year_range).pluck(:employee_id, :historical_import_batch_id)
        .group_by(&:first).transform_values { |rows| rows.map(&:last).uniq }
      return [] if batches_by_employee.empty?

      employees = @company.employees.to_a.index_by(&:id)
      batches_for = employees.transform_values do |employee|
        ids = Set.new
        while employee && ids.add?(employee.id)
          employee = employees[employee.previous_employee_id]
        end
        ids.flat_map { |id| batches_by_employee.fetch(id, []) } | batches_by_employee.fetch(nil, [])
      end
      # The annual ledger selects recorded W-2 paychecks. Today's classification
      # cannot tell us whether those paychecks need review.
      affected_employees = employees.values.reject { |employee| batches_for.fetch(employee.id).empty? }
      contexts = EmployeeYearFicaContext.batch(company: @company, employees: affected_employees, year: @year,
        excluding_pay_period_id: @excluding_pay_period_id)
      contexts.flat_map do |employee_id, context|
        context.recorded_increment(wages_delta: 0, tips_delta: 0, rules: rules)
        []
      rescue EmployeeYearFicaContext::UnreconciledLedgerError
        batches_for.fetch(employee_id)
      end.uniq
    end

    # The review identity is the entire company-year batch, even when only
    # some of its employees need the bounded path.
    def import_batches(batch_ids)
      HistoricalPaycheck.where(company: @company, pay_date: year_range, historical_import_batch_id: batch_ids)
        .includes(:employee, :historical_import_batch, :historical_worker, :historical_pay_period,
          :historical_paycheck_adjustments, :fica_basis_proof).order(:id).group_by(&:historical_import_batch_id)
    end

    def imported_proof(row, rules)
      ImportedPaycheckFicaEvidence.verified_bases(row, rules: rules, year: @year)
    end

    def disputed?
      rows = items
      rows.where(pay_period_id: committed_periods.voided.select(:id)).or(reversed_items)
        .or(rows.where(id: disposed_items.select(:id))).exists?
    end

    private

    def period_dates(period)
      PERIOD_DATES.map { |field| period.public_send(field) }
    end

    def legacy_missing_fica
      EmployeeYearFicaContext.reportable_items(company: @company, employee_ids: @employee_ids || @company.employees.select(:id),
        year: @year, excluding_pay_period_id: @excluding_pay_period_id).where(id: items.select(:id))
        .where("payroll_items.social_security_taxable_wages IS NULL OR payroll_items.social_security_taxable_tips IS NULL OR payroll_items.additional_medicare_taxable_wages IS NULL")
    end

    def reversed_items
      items.where.not(payroll_reversed_at: nil)
    end

    def disposed_items
      items.joins(:legacy_disposition).where.not(payroll_item_legacy_dispositions: { reason: PayrollItemLegacyDisposition::REASON })
    end

    def year_range
      Date.new(@year, 1, 1)..Date.new(@year, 12, 31)
    end

    def committed_periods
      scope = PayPeriod.where(company: @company, status: "committed", pay_date: year_range)
      @excluding_pay_period_id ? scope.where.not(id: @excluding_pay_period_id) : scope
    end

    def items
      scope = PayrollItem.where(company: @company, pay_period_id: committed_periods.select(:id)).where.not(employment_type: "contractor")
      @employee_ids ? scope.where(employee_id: @employee_ids) : scope
    end
  end
end
