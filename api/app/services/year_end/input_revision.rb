# frozen_string_literal: true

module YearEnd
  # A cheap revision of everything a client's checklist and W-2 filing
  # fingerprint read: for each table, the row count and the latest
  # updated_at, so a create, an update and a delete all change it. One
  # grouped query per table for any number of clients.
  #
  # A write that skips timestamps without changing a count (update_columns,
  # raw SQL) is not seen here. The checklist's filing fingerprint and the
  # mark-ready gate still catch those.
  module InputRevision
    def self.for(company_ids, year)
      company_ids = Array(company_ids)
      return {} if company_ids.empty?

      range = Date.new(year, 1, 1)..Date.new(year, 12, 31)
      employees = Employee.where(company_id: company_ids)
      pay_periods = PayPeriod.where(company_id: company_ids, pay_date: range)
      items = PayrollItem.joins(:pay_period).where(company_id: company_ids, pay_periods: { pay_date: range })
      sources = {
        company: stamps(Company.where(id: company_ids), "companies.id", "companies"),
        employees: stamps(employees, "employees.company_id", "employees"),
        tipped_occupations: stamps(EmployeeTippedOccupation.joins(:employee).merge(employees), "employees.company_id", "employee_tipped_occupations"),
        pay_periods: stamps(pay_periods, "pay_periods.company_id", "pay_periods", "MAX(pay_periods.committed_at)"),
        payroll_items: stamps(items, "payroll_items.company_id", "payroll_items"),
        deductions: stamps(PayrollItemDeduction.joins(payroll_item: :pay_period).merge(items), "payroll_items.company_id", "payroll_item_deductions"),
        field_entries: stamps(PayrollItemFieldEntry.joins(payroll_item: :pay_period).merge(items), "payroll_items.company_id", "payroll_item_field_entries"),
        deduction_types: stamps(DeductionType.where(company_id: company_ids), "deduction_types.company_id", "deduction_types"),
        field_definitions: stamps(PayrollFieldDefinition.where(company_id: company_ids), "payroll_field_definitions.company_id", "payroll_field_definitions"),
        filing_decisions: stamps(PayrollFilingResponsibility.where(company_id: company_ids, tax_year: year), "payroll_filing_responsibilities.company_id", "payroll_filing_responsibilities"),
        acknowledgements: stamps(YearEndAcknowledgement.where(company_id: company_ids, tax_year: year), "year_end_acknowledgements.company_id", "year_end_acknowledgements"),
        import_batches: stamps(HistoricalImportBatch.where(company_id: company_ids), "historical_import_batches.company_id", "historical_import_batches"),
        historical_paychecks: stamps(HistoricalPaycheck.where(company_id: company_ids, pay_date: range), "historical_paychecks.company_id", "historical_paychecks"),
        bridges: stamps(HistoricalYtdBridge.where(company_id: company_ids), "historical_ytd_bridges.company_id", "historical_ytd_bridges"),
        bridge_balances: stamps(HistoricalEmployeeYtdBalance.where(company_id: company_ids, tax_year: year), "historical_employee_ytd_balances.company_id", "historical_employee_ytd_balances"),
        adjustments: stamps(HistoricalPaycheckAdjustment.where(company_id: company_ids), "historical_paycheck_adjustments.company_id", "historical_paycheck_adjustments")
      }
      tax_config = AnnualTaxConfig.where(tax_year: year).pick(Arel.sql("COUNT(*)"), Arel.sql("EXTRACT(EPOCH FROM MAX(updated_at))")).map(&:to_s)

      company_ids.index_with do |company_id|
        Digest::SHA256.hexdigest([ sources.transform_values { |stamps| stamps[company_id] }, tax_config ].to_json)
      end
    end

    # { company_id => [count, latest updated_at, ...] } for one table, with
    # timestamps as epoch seconds so microseconds survive.
    def self.stamps(scope, group_column, table, *extra)
      columns = [ "COUNT(*)", "EXTRACT(EPOCH FROM MAX(#{table}.updated_at))", *extra.map { |sql| "EXTRACT(EPOCH FROM #{sql})" } ]
      scope.group(Arel.sql(group_column)).pluck(Arel.sql(group_column), *columns.map { |sql| Arel.sql(sql) })
           .to_h { |company_id, *values| [ company_id, values.map(&:to_s) ] }
    end
    private_class_method :stamps
  end
end
