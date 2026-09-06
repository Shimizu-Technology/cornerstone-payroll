# frozen_string_literal: true

module QuickbooksHistory
  class ReportBuilder
    MAX_EXPORT_ROWS = 100_000
    MAX_PDF_ROWS = 10_000
    REPORTS = {
      "register" => {
        title: "Historical Payroll Register",
        description: "Paycheck-level QuickBooks history with earnings, taxes, deductions, net pay, and employer cost.",
        columns: [
          [ :pay_date, "Pay date", :date ], [ :period, "Pay period", :text ],
          [ :record_kind, "Record type", :text ], [ :employee, "Employee", :text ],
          [ :hours, "Hours", :number ], [ :gross_pay, "Gross pay", :money ],
          [ :pretax_deductions, "Pre-tax deductions", :money ], [ :employee_taxes, "Employee taxes", :money ],
          [ :after_tax_deductions, "After-tax deductions", :money ], [ :net_pay, "Net pay", :money ],
          [ :employer_taxes, "Employer taxes", :money ], [ :employer_contributions, "Employer contributions", :money ],
          [ :total_payroll_cost, "Total payroll cost", :money ], [ :payment_method, "Pay method", :text ],
          [ :check_number, "Check number", :text ], [ :source_batch, "Source batch", :text ]
        ]
      },
      "employee_summary" => {
        title: "Historical Employee Summary",
        description: "QuickBooks payroll totals by worker, with detailed paychecks and opening summaries counted separately.",
        columns: [
          [ :employee, "Employee", :text ], [ :detailed_paychecks, "Detailed paychecks", :number ],
          [ :opening_summaries, "Opening summaries", :number ], [ :hours, "Hours", :number ],
          [ :gross_pay, "Gross pay", :money ], [ :pretax_deductions, "Pre-tax deductions", :money ],
          [ :employee_taxes, "Employee taxes", :money ], [ :after_tax_deductions, "After-tax deductions", :money ],
          [ :net_pay, "Net pay", :money ], [ :employer_taxes, "Employer taxes", :money ],
          [ :employer_contributions, "Employer contributions", :money ],
          [ :total_payroll_cost, "Total payroll cost", :money ]
        ]
      },
      "taxes" => {
        title: "Historical Tax Detail",
        description: "Employee and employer tax components exactly as recorded in the QuickBooks payroll snapshots.",
        columns: [
          [ :pay_date, "Pay date", :date ], [ :record_kind, "Record type", :text ],
          [ :employee, "Employee", :text ], [ :tax_side, "Tax side", :text ],
          [ :component, "Tax component", :text ], [ :amount, "Amount", :money ],
          [ :source_batch, "Source batch", :text ]
        ]
      },
      "deductions" => {
        title: "Historical Deductions & Contributions",
        description: "Pre-tax deductions, after-tax deductions, loans, retirement items, and employer contributions preserved from QuickBooks.",
        columns: [
          [ :pay_date, "Pay date", :date ], [ :record_kind, "Record type", :text ],
          [ :employee, "Employee", :text ], [ :category, "Category", :text ],
          [ :component, "Component", :text ], [ :amount, "Amount", :money ],
          [ :source_batch, "Source batch", :text ]
        ]
      },
      "checks" => {
        title: "Historical Check & Payment History",
        description: "QuickBooks payment method, source status, available check number, and paycheck totals.",
        columns: [
          [ :pay_date, "Pay date", :date ], [ :period, "Pay period", :text ],
          [ :record_kind, "Record type", :text ], [ :employee, "Employee", :text ],
          [ :payment_method, "Pay method", :text ], [ :check_number, "Check number", :text ],
          [ :source_status, "Source status", :text ], [ :gross_pay, "Gross pay", :money ],
          [ :net_pay, "Net pay", :money ], [ :source_batch, "Source batch", :text ]
        ]
      }
    }.freeze
    TOTAL_FIELDS = %i[
      gross_pay pretax_deductions employee_taxes after_tax_deductions net_pay
      employer_taxes employer_contributions total_payroll_cost
    ].freeze

    def initialize(company:, report_type:, year: nil, worker_key: nil)
      @company = company
      @report_type = report_type.to_s
      @year = normalized_year(year)
      @worker_key = worker_key.to_s.presence
      raise ArgumentError, "Unknown historical report" unless REPORTS.key?(@report_type)
    end

    def call(page: nil, per_page: nil)
      rows, row_count = if page && per_page
        paginated_rows(page: page, per_page: per_page)
      else
        export_rows
      end
      definition = REPORTS.fetch(report_type)

      {
        report_type: report_type,
        title: definition.fetch(:title),
        description: definition.fetch(:description),
        generated_at: Time.current,
        source_statement: "Authoritative QuickBooks snapshots — never recalculated by Cornerstone Payroll",
        filters: filter_payload,
        available_years: available_years,
        available_workers: available_workers,
        columns: definition.fetch(:columns).map { |key, label, format| { key: key, label: label, format: format } },
        rows: rows,
        summary: summary(row_count: row_count),
        coverage: coverage,
        warnings: warnings,
        provenance: provenance
      }
    end

    def sheets(report)
      columns = report.fetch(:columns)
      [
        {
          name: "Report information",
          rows: information_rows(report),
          column_widths: [ 28, 90 ],
          show_grid_lines: false
        },
        {
          name: REPORTS.fetch(report_type).fetch(:title),
          rows: [ columns.pluck(:label) ] + report.fetch(:rows).map do |row|
            columns.map { |column| row.fetch(column.fetch(:key)) }
          end,
          row_style_rules: [ { rows: [ 0 ], style: :header } ],
          styles: { header: { b: true, bg_color: "EAF1F8", fg_color: "172033" } },
          show_grid_lines: false
        },
        {
          name: "Source batches",
          rows: provenance_rows(report),
          row_style_rules: [ { rows: [ 0 ], style: :header } ],
          styles: { header: { b: true, bg_color: "EAF1F8", fg_color: "172033" } },
          show_grid_lines: false
        }
      ]
    end

    def filename(extension)
      filter = [ year || "all-years", worker_key.present? ? "one-worker" : "all-workers" ].join("_")
      "historical_#{report_type}_company_#{company.id}_#{filter}.#{extension}"
    end

    private

    attr_reader :company, :report_type, :year, :worker_key

    def normalized_year(value)
      return nil if value.blank?

      parsed = Integer(value, exception: false)
      raise ArgumentError, "year must be between 1900 and #{Date.current.year + 1}" unless parsed&.between?(1900, Date.current.year + 1)

      parsed
    end

    def visible_scope
      HistoricalPaycheck.joins(:historical_import_batch, :historical_worker, :historical_pay_period)
                         .merge(HistoricalImportBatch.visible_history)
                         .where(historical_paychecks: { company_id: company.id })
    end

    def report_scope
      scope = visible_scope.includes(:historical_import_batch, :historical_worker, :historical_pay_period)
      scope = scope.where(pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31)) if year
      scope = scope.where(historical_workers: { normalized_name: worker_key }) if worker_key
      scope.order(:pay_date, :source_employee_name, :id)
    end

    def export_rows
      rows = build_rows(report_scope.to_a)
      [ rows, rows.size ]
    end

    def paginated_rows(page:, per_page:)
      offset = (page - 1) * per_page
      return paginated_paycheck_rows(offset: offset, per_page: per_page) if report_type.in?(%w[register checks])

      rows = if report_type == "employee_summary"
        employee_summary_rows_streamed(offset: offset, per_page: per_page)
      else
        expanded_rows_page(offset: offset, per_page: per_page)
      end
      [ rows.fetch(:page), rows.fetch(:total) ]
    end

    def paginated_paycheck_rows(offset:, per_page:)
      page_paychecks = report_scope.offset(offset).limit(per_page).to_a
      [ build_rows(page_paychecks), report_scope.except(:includes, :order).count ]
    end

    def expanded_rows_page(offset:, per_page:)
      selected = []
      total = 0
      each_paycheck_in_report_order do |paycheck|
        expanded_rows_for(paycheck).each do |row|
          selected << row if total >= offset && selected.size < per_page
          total += 1
        end
      end
      { page: selected, total: total }
    end

    def employee_summary_rows_streamed(offset:, per_page:)
      groups = {}
      each_paycheck_in_report_order do |paycheck|
        key = paycheck.historical_worker.normalized_name
        group = groups[key] ||= empty_employee_summary(paycheck)
        group[:detailed_paychecks] += 1 if regular?(paycheck)
        group[:opening_summaries] += 1 unless regular?(paycheck)
        group[:hours] += paycheck.hours_total.to_d
        TOTAL_FIELDS.each { |field| group[field] += paycheck.public_send(field).to_d }
      end
      rows = groups.values.sort_by { |row| row.fetch(:employee).downcase }
      { page: rows.slice(offset, per_page) || [], total: rows.size }
    end

    def empty_employee_summary(paycheck)
      {
        employee: display_employee(paycheck),
        detailed_paychecks: 0,
        opening_summaries: 0,
        hours: 0.to_d,
        **TOTAL_FIELDS.to_h { |field| [ field, 0.to_d ] }
      }
    end

    def expanded_rows_for(paycheck)
      case report_type
      when "taxes"
        tax_rows([ paycheck ])
      when "deductions"
        deduction_rows([ paycheck ])
      else
        []
      end
    end

    def each_paycheck_in_report_order(batch_size: 1_000)
      cursor = nil
      loop do
        scope = report_scope.reorder(:pay_date, :source_employee_name, :id).limit(batch_size)
        if cursor
          scope = scope.where(
            "(historical_paychecks.pay_date, historical_paychecks.source_employee_name, historical_paychecks.id) > (?, ?, ?)",
            *cursor
          )
        end
        batch = scope.to_a
        break if batch.empty?

        batch.each { |paycheck| yield paycheck }
        last = batch.last
        cursor = [ last.pay_date, last.source_employee_name, last.id ]
      end
    end

    def available_years
      visible_scope.distinct.pluck(:pay_date).filter_map(&:year).uniq.sort.reverse
    end

    def available_workers
      HistoricalWorker.joins(:historical_import_batch)
                      .merge(HistoricalImportBatch.visible_history)
                      .where(company_id: company.id)
                      .select(:normalized_name, :source_name)
                      .order(:normalized_name, :source_name)
                      .each_with_object({}) do |worker, result|
        result[worker.normalized_name] ||= worker.source_name.delete_prefix("*")
      end.map { |key, name| { key: key, name: name } }
    end

    def build_rows(paychecks)
      case report_type
      when "register" then register_rows(paychecks)
      when "employee_summary" then employee_summary_rows(paychecks)
      when "taxes" then tax_rows(paychecks)
      when "deductions" then deduction_rows(paychecks)
      when "checks" then check_rows(paychecks)
      end
    end

    def register_rows(paychecks)
      paychecks.map do |paycheck|
        base_row(paycheck).merge(
          period: period_label(paycheck),
          hours: paycheck.hours_total,
          gross_pay: paycheck.gross_pay,
          pretax_deductions: paycheck.pretax_deductions,
          employee_taxes: paycheck.employee_taxes,
          after_tax_deductions: paycheck.after_tax_deductions,
          net_pay: paycheck.net_pay,
          employer_taxes: paycheck.employer_taxes,
          employer_contributions: paycheck.employer_contributions,
          total_payroll_cost: paycheck.total_payroll_cost,
          payment_method: paycheck.payment_method,
          check_number: paycheck.check_number
        )
      end
    end

    def employee_summary_rows(paychecks)
      paychecks.group_by { |paycheck| paycheck.historical_worker.normalized_name }.values.map do |group|
        first = group.first
        totals = money_totals(group)
        {
          employee: display_employee(first),
          detailed_paychecks: group.count { |paycheck| regular?(paycheck) },
          opening_summaries: group.count { |paycheck| !regular?(paycheck) },
          hours: group.sum { |paycheck| paycheck.hours_total.to_d },
          **totals
        }
      end.sort_by { |row| row.fetch(:employee).downcase }
    end

    def tax_rows(paychecks)
      paychecks.flat_map do |paycheck|
        component_rows(paycheck, :employee_tax_breakdown, :employee_taxes, "Employee") +
          component_rows(paycheck, :employer_tax_breakdown, :employer_taxes, "Employer")
      end.map { |row| row.transform_keys { |key| key == :category ? :tax_side : key } }
    end

    def deduction_rows(paychecks)
      paychecks.flat_map do |paycheck|
        component_rows(paycheck, :pretax_deduction_breakdown, :pretax_deductions, "Pre-tax deduction") +
          component_rows(paycheck, :after_tax_deduction_breakdown, :after_tax_deductions, "After-tax deduction") +
          component_rows(paycheck, :employer_contribution_breakdown, :employer_contributions, "Employer contribution")
      end
    end

    def check_rows(paychecks)
      paychecks.map do |paycheck|
        base_row(paycheck).merge(
          period: period_label(paycheck),
          payment_method: paycheck.payment_method,
          check_number: paycheck.check_number,
          source_status: paycheck.source_status,
          gross_pay: paycheck.gross_pay,
          net_pay: paycheck.net_pay
        )
      end
    end

    def component_rows(paycheck, breakdown_field, total_field, category)
      breakdown = Array(paycheck.public_send(breakdown_field))
      rows = breakdown.filter_map do |entry|
        component = entry.to_h.with_indifferent_access
        amount = decimal(component[:amount])
        next if amount.zero?

        component_row(paycheck, category, component[:label].presence || "Unlabeled component", amount)
      end
      difference = paycheck.public_send(total_field).to_d - rows.sum { |row| row.fetch(:amount) }
      rows << component_row(paycheck, category, "Unclassified #{category.downcase}", difference) unless difference.zero?
      rows
    end

    def component_row(paycheck, category, component, amount)
      base_row(paycheck).slice(:pay_date, :record_kind, :employee, :source_batch).merge(
        category: category,
        component: component,
        amount: amount
      )
    end

    def base_row(paycheck)
      {
        pay_date: paycheck.pay_date,
        record_kind: regular?(paycheck) ? "Detailed paycheck" : "Opening summary",
        employee: display_employee(paycheck),
        source_batch: paycheck.historical_import_batch.source_label
      }
    end

    def display_employee(paycheck)
      paycheck.source_employee_name.delete_prefix("*")
    end

    def period_label(paycheck)
      prefix = regular?(paycheck) ? nil : "Opening summary: "
      "#{prefix}#{paycheck.period_start.strftime('%m/%d/%Y')} – #{paycheck.period_end.strftime('%m/%d/%Y')}"
    end

    def regular?(paycheck)
      paycheck.historical_pay_period.period_type == "regular"
    end

    def summary(row_count:)
      scope = report_scope.except(:includes, :order)
      regular = scope.where(historical_pay_periods: { period_type: "regular" })
      opening = scope.where(historical_pay_periods: { period_type: "opening_summary" })
      {
        row_count: row_count,
        paycheck_count: scope.count,
        detailed_paycheck_count: regular.count,
        opening_summary_count: opening.count,
        totals: relation_money_totals(scope),
        detailed_paycheck_totals: relation_money_totals(regular),
        opening_summary_totals: relation_money_totals(opening),
        missing_check_number_count: scope.where(check_number: [ nil, "" ]).count
      }
    end

    def money_totals(paychecks)
      TOTAL_FIELDS.to_h { |field| [ field, paychecks.sum { |paycheck| paycheck.public_send(field).to_d } ] }
    end

    def relation_money_totals(scope)
      expressions = TOTAL_FIELDS.map do |field|
        Arel.sql("COALESCE(SUM(historical_paychecks.#{field}), 0)")
      end
      values = scope.pick(*expressions) || Array.new(TOTAL_FIELDS.size, 0)
      TOTAL_FIELDS.zip(Array(values)).to_h.transform_values(&:to_d)
    end

    def coverage
      scope = report_scope.except(:includes, :order)
      regular = scope.where(historical_pay_periods: { period_type: "regular" })
      opening = scope.where(historical_pay_periods: { period_type: "opening_summary" })
      {
        first_detailed_pay_date: regular.minimum(:pay_date),
        last_detailed_pay_date: regular.maximum(:pay_date),
        opening_summary_start: opening.minimum(:period_start),
        opening_summary_end: opening.maximum(:period_end)
      }
    end

    def warnings
      scope = report_scope.except(:includes, :order)
      result = []
      opening = scope.where(historical_pay_periods: { period_type: "opening_summary" })
      opening_count = opening.count
      if opening_count.positive?
        result << "#{opening_count} opening summary record(s) cover #{opening.minimum(:period_start)} through #{opening.maximum(:period_end)}. They are shown separately and are not individual pay periods."
      end
      missing_checks = scope.where(check_number: [ nil, "" ]).count
      result << "QuickBooks did not provide a check number for #{missing_checks} record(s)." if missing_checks.positive?
      result
    end

    def provenance
      scope = report_scope.except(:includes, :order)
      batch_ids = scope.distinct.pluck(:historical_import_batch_id)
      HistoricalImportBatch.where(id: batch_ids).includes(:historical_import_source_files).order(:id).map do |batch|
        sources = batch.historical_import_source_files.to_a
        {
          batch_id: batch.id,
          source_label: batch.source_label,
          status: batch.status,
          bundle_digest: batch.bundle_digest,
          importer_version: batch.importer_version,
          applied_at: batch.applied_at,
          locked_at: batch.locked_at,
          retained_file_count: sources.size,
          verified_file_count: sources.count(&:verified?)
        }
      end
    end

    def filter_payload
      { year: year, worker_key: worker_key }
    end

    def information_rows(report)
      coverage = report.fetch(:coverage)
      summary_data = report.fetch(:summary)
      [
        [ "Report", report.fetch(:title) ],
        [ "Company", company.name ],
        [ "Source", report.fetch(:source_statement) ],
        [ "Year filter", year || "All years" ],
        [ "Worker filter", worker_key || "All workers" ],
        [ "Generated at", report.fetch(:generated_at) ],
        [ "Detailed paychecks", summary_data.fetch(:detailed_paycheck_count) ],
        [ "Opening summaries", summary_data.fetch(:opening_summary_count) ],
        [ "Detailed pay-date coverage", [ coverage[:first_detailed_pay_date], coverage[:last_detailed_pay_date] ].compact.join(" through ").presence || "None" ],
        [ "Opening-summary coverage", [ coverage[:opening_summary_start], coverage[:opening_summary_end] ].compact.join(" through ").presence || "None" ],
        *report.fetch(:warnings).map { |warning| [ "Source limitation", warning ] }
      ]
    end

    def provenance_rows(report)
      headers = [ "Batch ID", "Source label", "Status", "Bundle SHA-256", "Importer version", "Applied at", "Locked at", "Retained files", "Verified files" ]
      rows = report.fetch(:provenance).map do |source|
        [
          source.fetch(:batch_id), source.fetch(:source_label), source.fetch(:status),
          source.fetch(:bundle_digest), source.fetch(:importer_version), source.fetch(:applied_at),
          source.fetch(:locked_at), source.fetch(:retained_file_count), source.fetch(:verified_file_count)
        ]
      end
      [ headers ] + rows
    end

    def decimal(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      0.to_d
    end
  end
end
