# frozen_string_literal: true

require "csv"

module QuickbooksHistory
  class EvidenceCoverageManifest
    VERSION = 1
    REQUIRED_REPORTS = QuickbooksHistory::BundleParser::REQUIRED_REPORTS
    REPORT_CATALOG = {
      "payroll_details" => {
        label: "Payroll Details",
        layer: "paycheck_reconciliation",
        role: "Authoritative paycheck values",
        description: "Supplies the imported paycheck amounts and itemized payroll components.",
        required_headers: [ "Name", "Pay date", "Time period", "Gross pay - total", "Net pay" ]
      },
      "paycheck_history" => {
        label: "Paycheck History",
        layer: "paycheck_reconciliation",
        role: "Payment and check cross-check",
        description: "Matches each detailed paycheck by worker, pay date, gross, and net and retains check information.",
        required_headers: [ "Pay date", "Name", "Total pay", "Net pay", "Check Number" ]
      },
      "payroll_summary" => {
        label: "Payroll Summary",
        layer: "paycheck_reconciliation",
        role: "Paycheck-level totals cross-check",
        description: "Reconciles paycheck totals. It is not the quarterly or year-to-date evidence report.",
        required_headers: [
          "Pay date", "Name", "Gross pay", "Pretax deductions", "Employee taxes",
          "Aftertax deduction", "Net pay", "Employer taxes", "Company contributions", "Total payroll cost"
        ]
      },
      "employee_details" => {
        label: "Employee Details",
        layer: "worker_setup",
        role: "Private employee setup evidence",
        description: "Supports employee identity, tax, and payroll setup review without exposing private values in this manifest.",
        required_headers: [ "Personal info", "Hire date" ]
      },
      "employee_directory" => {
        label: "Employee Directory",
        layer: "worker_setup",
        role: "Roster and hire-date cross-check",
        description: "Cross-checks the source roster and hire dates used during worker matching.",
        required_headers: [ "Name", "Hire date" ]
      },
      "tax_and_wage_summary" => {
        label: "Tax & Wage Summary",
        layer: "tax_wage_ytd",
        role: "Quarterly, annual, and YTD tax evidence",
        description: "Reconciles tax and wage totals by source period and supplies the YTD evidence layer.",
        required_headers: [ "Tax types", "Total wages", "Excess wages", "Taxable wages", "Tax amount" ]
      },
      "payroll_summary_by_employee" => {
        label: "Payroll Summary by Employee",
        layer: "supplemental",
        role: "Supplemental reference",
        description: "Retained for reference; it is not the authoritative Payroll Summary or Tax & Wage Summary.",
        required_headers: []
      }
    }.freeze
    CSV_HEADERS = [
      "Position", "Source file", "Report classification", "Evidence layer", "Evidence role", "Required",
      "Required headers", "Header validation", "Rows", "Coverage start", "Coverage end", "Coverage scope",
      "Retention status", "Verified at", "Bytes", "SHA-256", "Purpose"
    ].freeze

    def initialize(batch:)
      @batch = batch
    end

    def call
      rows = manifest_rows
      tax_rows = rows.select { |row| row[:report_type] == "tax_and_wage_summary" }
      required_rows = rows.select { |row| row[:required] }
      required_types_present = required_rows.map { |row| row[:report_type] }.uniq
      required_types_validated = required_rows.filter_map do |row|
        row[:report_type] if row[:header_validation] == "validated"
      end.uniq
      regular_dates = batch.historical_paychecks.joins(:historical_pay_period)
                           .where(historical_pay_periods: { period_type: "regular" })

      {
        version: VERSION,
        batch_id: batch.id,
        source_system: batch.source_system,
        source_label: batch.source_label,
        bundle_digest: batch.bundle_digest,
        batch_status: batch.status,
        generated_at: Time.current.iso8601,
        summary: {
          file_count: rows.length,
          verified_file_count: rows.count { |row| row[:retention_status] == "verified" },
          required_report_count: REQUIRED_REPORTS.length,
          required_present_count: required_types_present.length,
          required_headers_validated_count: required_types_validated.length,
          tax_wage_report_count: tax_rows.count { |row| row[:header_validation] == "validated" },
          tax_wage_years: tax_rows.filter_map { |row| row[:coverage_end]&.year }.uniq.sort,
          first_detailed_pay_date: regular_dates.minimum(:pay_date),
          last_detailed_pay_date: regular_dates.maximum(:pay_date),
          source_retention_ready: batch.source_files_complete_and_verified?,
          paycheck_reconciliation_ready: required_types_present.length == REQUIRED_REPORTS.length &&
            required_types_validated.length == REQUIRED_REPORTS.length &&
            batch.reconciliation_summary.to_h["passed"] == true,
          ytd_evidence_ready: batch.tax_wage_reconciliation.to_h["passed"] == true
        },
        taxonomy: {
          paycheck_reconciliation: "Payroll Details is authoritative. Paycheck History and Payroll Summary independently cross-check each paid paycheck.",
          tax_wage_ytd: "Tax & Wage Summary files are the separate quarterly, annual, and year-to-date tax evidence layer.",
          privacy: "The downloadable manifest uses source positions, classifications, coverage, counts, and fingerprints; it excludes filenames, employee rows, and private source contents."
        },
        rows: rows
      }
    end

    def to_csv
      CSV.generate do |csv|
        csv << CSV_HEADERS
        call.fetch(:rows).each do |row|
          csv << [
            row[:position], "Source file #{row[:position]}", row[:report_label], row[:evidence_layer], row[:evidence_role],
            row[:required] ? "Yes" : "No", row[:required_headers].join(" | "), row[:header_validation],
            row[:row_count], row[:coverage_start], row[:coverage_end], row[:coverage_scope],
            row[:retention_status], row[:verified_at], row[:byte_size], row[:sha256], row[:description]
          ]
        end
      end
    end

    def filename
      "quickbooks_evidence_manifest_#{batch.company.name.parameterize.presence || batch.company_id}_batch_#{batch.id}.csv"
    end

    private

    attr_reader :batch

    def manifest_rows
      retained_by_position = batch.historical_import_source_files.in_manifest_order.index_by(&:position)
      tax_by_position = batch.historical_tax_wage_reports.index_by(&:source_position)
      payroll_coverage = payroll_coverage_dates

      Array(batch.source_file_manifest).sort_by { |entry| entry.fetch("position", 0).to_i }.map do |entry|
        position = entry.fetch("position", 0).to_i
        report_type = entry.fetch("report_type", "unknown").to_s
        retained = retained_by_position[position]
        tax_report = tax_by_position[position]
        catalog = REPORT_CATALOG.fetch(report_type, fallback_catalog(report_type))
        coverage_start, coverage_end, coverage_scope = coverage_for(report_type, tax_report, payroll_coverage)

        {
          position: position + 1,
          filename: entry.fetch("filename", retained&.original_filename).to_s,
          report_type: report_type,
          report_label: catalog.fetch(:label),
          evidence_layer: catalog.fetch(:layer),
          evidence_role: catalog.fetch(:role),
          description: catalog.fetch(:description),
          required: REQUIRED_REPORTS.include?(report_type),
          required_headers: catalog.fetch(:required_headers),
          header_validation: header_validation(entry, report_type, tax_report),
          row_count: entry["row_count"],
          coverage_start: coverage_start,
          coverage_end: coverage_end,
          coverage_scope: coverage_scope,
          retention_status: retained&.verification_status || "missing",
          verified_at: retained&.verified_at,
          byte_size: retained&.byte_size || entry["byte_size"],
          sha256: retained&.sha256 || entry["sha256"]
        }
      end
    end

    def payroll_coverage_dates
      scope = batch.historical_paychecks.joins(:historical_pay_period)
                   .where(historical_pay_periods: { period_type: "regular" })
      [ scope.minimum(:pay_date), scope.maximum(:pay_date) ]
    end

    def coverage_for(report_type, tax_report, payroll_coverage)
      if tax_report
        return [ tax_report.period_start, tax_report.period_end, tax_report.scope ]
      end
      if report_type.in?(%w[payroll_details paycheck_history payroll_summary])
        return [ payroll_coverage.first, payroll_coverage.last, "pay dates" ]
      end

      [ nil, nil, report_type.in?(%w[employee_details employee_directory]) ? "worker roster" : nil ]
    end

    def header_validation(entry, report_type, tax_report)
      return "failed" if report_type == "unreadable_spreadsheet" || entry["parse_error"].present?
      return tax_report ? "validated" : "classified" if report_type == "tax_and_wage_summary"
      catalog = REPORT_CATALOG[report_type]
      return "validated" if catalog && catalog.fetch(:required_headers).any? && entry["row_count"].present?

      "not_applicable"
    end

    def fallback_catalog(report_type)
      expected = report_type == "unreadable_spreadsheet" ? "Unreadable spreadsheet" : report_type.humanize.presence || "Supporting file"
      {
        label: expected,
        layer: "supplemental",
        role: "Retained supporting source",
        description: "Retained with the source bundle but not used as an authoritative reconciliation report.",
        required_headers: []
      }
    end
  end
end
