# frozen_string_literal: true

require "digest"

module QuickbooksHistory
  class BundleParser
    IMPORTER_VERSION = "quickbooks-online-payroll-v5"
    REQUIRED_REPORTS = %w[
      payroll_details paycheck_history payroll_summary employee_details employee_directory
    ].freeze
    MAX_FILE_COUNT = 75
    MAX_FILE_BYTES = 30.megabytes
    MAX_BUNDLE_BYTES = 150.megabytes
    MAX_WORKER_COUNT = 2_000
    MAX_PERIOD_COUNT = 2_000
    MAX_PAYCHECK_COUNT = 250_000
    ALLOWED_EXTENSIONS = %w[.xls .xlsx .pdf .jpg .jpeg .png].freeze

    Result = Struct.new(
      :bundle_digest,
      :company_name,
      :source_label,
      :manifest,
      :workers,
      :periods,
      :paychecks,
      :summary,
      :reconciliation,
      :tax_wage_reports,
      :tax_wage_reconciliation,
      :warnings,
      :errors,
      :source_files,
      keyword_init: true
    )

    SourceFile = Struct.new(:original_filename, :path, :size, :content_type, :source, keyword_init: true)

    def initialize(files:)
      @files = Array(files).map { |file| normalize_file(file) }
    end

    def call
      validate_bundle!
      inventory = files.map { |file| inventory_file(file) }
      digest_entries = inventory.map { |entry| "#{entry.fetch(:filename)}:#{entry.fetch(:sha256)}" }.sort
      bundle_digest = Digest::SHA256.hexdigest(digest_entries.join("\n"))
      report_entries = inventory.select { |entry| entry[:rows].present? }
      reports = report_entries.index_by { |entry| entry.fetch(:report_type) }
      missing = REQUIRED_REPORTS - reports.keys
      errors = missing.map { |type| "Missing required QuickBooks report: #{type.humanize}" }
      duplicate_required_reports(report_entries).each do |type|
        errors << "Multiple #{type.humanize} reports were supplied; upload one authoritative report of each required type"
      end
      required_entries = report_entries.select { |entry| REQUIRED_REPORTS.include?(entry.fetch(:report_type)) }
      errors << "Every required QuickBooks report must identify its company" if required_entries.any? { |entry| entry[:company_name].blank? }
      errors << "Required QuickBooks reports name more than one company" if multiple_source_companies?(required_entries)
      inventory.select do |entry|
        entry[:report_type] == "unreadable_spreadsheet" && REQUIRED_REPORTS.include?(entry[:expected_report_type])
      end.each do |entry|
        errors << "#{entry.fetch(:filename)} could not be read as a spreadsheet"
      end

      return empty_result(bundle_digest, inventory, errors) if errors.any?

      detail = parse_payroll_details(reports.fetch("payroll_details").fetch(:rows))
      history = parse_paycheck_history(reports.fetch("paycheck_history").fetch(:rows))
      payroll_summary = parse_payroll_summary(reports.fetch("payroll_summary").fetch(:rows))
      validate_distinct_worker_names!(detail.fetch(:paychecks))
      reconcile_paycheck_history!(detail, history)
      reconcile_payroll_summary!(detail, payroll_summary)
      workers = build_workers(
        detail.fetch(:paychecks),
        reports.fetch("employee_directory").fetch(:rows),
        reports.fetch("employee_details").fetch(:rows)
      )
      periods = build_periods(detail.fetch(:paychecks))
      validate_record_counts!(workers, periods, detail.fetch(:paychecks))
      reconciliation = build_reconciliation(detail.fetch(:paychecks), history, payroll_summary)
      company_name = inventory.find { |entry| entry[:report_type] == "payroll_details" }.fetch(:company_name)
      tax_wage_parse_errors = inventory.filter_map do |entry|
        next unless entry[:report_type] == "unreadable_spreadsheet" && entry[:expected_report_type] == "tax_and_wage_summary"

        "#{entry.fetch(:filename)} could not be read as a Tax and Wage Summary spreadsheet"
      end
      tax_wage_reports = inventory.each_with_index.filter_map do |entry, position|
        next unless entry[:report_type] == "tax_and_wage_summary" && entry[:rows].present?

        begin
          parse_tax_wage_report(entry, position: position)
        rescue ArgumentError => e
          tax_wage_parse_errors << e.message
          nil
        end
      end
      tax_wage_reconciliation = build_tax_wage_reconciliation(
        detail.fetch(:paychecks),
        tax_wage_reports,
        company_name: company_name,
        parse_errors: tax_wage_parse_errors
      )
      warnings = build_warnings(detail.fetch(:paychecks), history, inventory, tax_wage_reports: tax_wage_reports)
      if tax_wage_reconciliation["not_available"]
        warnings << "Tax and Wage Summary evidence is not available. Historical YTD activation and v5 cutover verification remain blocked until those reports are imported."
      end
      max_pay_date = detail.fetch(:paychecks).map { |row| row.fetch(:pay_date) }.max
      all_errors = reconciliation.fetch("errors") + tax_wage_reconciliation.fetch("errors")
      summary = build_summary(detail.fetch(:paychecks), workers, periods, inventory)
      summary["tax_wage_report_count"] = tax_wage_reports.size

      Result.new(
        bundle_digest: bundle_digest,
        company_name: company_name,
        source_label: "#{company_name} QuickBooks history through #{max_pay_date.iso8601}",
        manifest: inventory.each_with_index.map { |entry, position| entry.except(:rows).merge(position: position) },
        workers: workers,
        periods: periods,
        paychecks: detail.fetch(:paychecks),
        summary: summary,
        reconciliation: reconciliation,
        tax_wage_reports: tax_wage_reports,
        tax_wage_reconciliation: tax_wage_reconciliation,
        warnings: warnings,
        errors: all_errors,
        source_files: files
      )
    end

    private

    attr_reader :files

    def duplicate_required_reports(entries)
      entries.group_by { |entry| entry.fetch(:report_type) }
             .select { |type, grouped| REQUIRED_REPORTS.include?(type) && grouped.many? }
             .keys
    end

    def multiple_source_companies?(entries)
      entries.select { |entry| REQUIRED_REPORTS.include?(entry.fetch(:report_type)) }
             .filter_map { |entry| NameNormalizer.call(entry[:company_name]) if entry[:company_name].present? }
             .uniq
             .many?
    end

    def normalize_file(file)
      return file if file.is_a?(SourceFile)

      filename = file.respond_to?(:original_filename) ? file.original_filename : File.basename(file.to_s)
      path = if file.respond_to?(:tempfile)
        file.tempfile.path
      elsif file.respond_to?(:path)
        file.path
      else
        file.to_s
      end
      size = if file.respond_to?(:tempfile) || file.is_a?(File)
        file.size
      else
        File.size(path)
      end
      # Keep the upload object alive while parsing. Rack may unlink its tempfile
      # when the uploaded-file wrapper is garbage collected.
      content_type = file.respond_to?(:content_type) ? file.content_type : nil
      SourceFile.new(original_filename: filename, path: path, size: size, content_type: content_type, source: file)
    end

    def validate_bundle!
      raise ArgumentError, "Select at least one QuickBooks export file" if files.empty?
      raise ArgumentError, "A QuickBooks bundle can contain at most #{MAX_FILE_COUNT} files" if files.size > MAX_FILE_COUNT
      raise ArgumentError, "The QuickBooks bundle is larger than #{MAX_BUNDLE_BYTES / 1.megabyte} MB" if files.sum(&:size).to_i > MAX_BUNDLE_BYTES

      files.each do |file|
        extension = File.extname(file.original_filename.to_s).downcase
        raise ArgumentError, "Unsupported file type: #{extension.presence || 'unknown'}" unless ALLOWED_EXTENSIONS.include?(extension)
        raise ArgumentError, "#{safe_filename(file)} is empty" unless file.size.to_i.positive?
        raise ArgumentError, "#{safe_filename(file)} is larger than #{MAX_FILE_BYTES / 1.megabyte} MB" if file.size.to_i > MAX_FILE_BYTES
        raise ArgumentError, "QuickBooks export file is missing" unless File.file?(file.path.to_s)
      end
    end

    def inventory_file(file)
      extension = File.extname(file.original_filename.to_s).downcase
      entry = {
        filename: safe_filename(file),
        sha256: Digest::SHA256.file(file.path.to_s).hexdigest,
        byte_size: file.size.to_i,
        report_type: supplemental_report_type(extension)
      }
      return entry unless extension.in?(%w[.xls .xlsx])

      parse_error = nil
      rows = begin
        SpreadsheetReader.read(path: file.path, extension: extension)
      rescue StandardError => e
        Rails.logger.warn(
          "QuickbooksHistory::BundleParser failed to read #{entry.fetch(:filename)}: #{e.class}: #{e.message}"
        )
        parse_error = "#{e.class}: #{sanitized_parse_error_message(e, file)}"
        nil
      end
      if rows.nil?
        return entry.merge(
          report_type: "unreadable_spreadsheet",
          expected_report_type: classify_report("", file.original_filename),
          parse_error: parse_error
        )
      end

      title = rows.first(6).flatten.compact.map(&:to_s).find { |value| value.downcase.include?("report") }.to_s
      report_type = classify_report(title, file.original_filename)
      entry.merge(
        report_type: report_type,
        company_name: rows.dig(0, 0).to_s.strip,
        row_count: rows.size,
        rows: parseable_report?(report_type) ? rows : nil
      )
    end

    def safe_filename(file)
      File.basename(file.original_filename.to_s).gsub(/[\u0000-\u001f]/, "").truncate(240)
    end

    def sanitized_parse_error_message(error, file)
      error.message.to_s
           .scrub("")
           .gsub(file.path.to_s, safe_filename(file))
           .gsub(Rails.root.to_s, "[application]")
           .gsub(/[\u0000-\u001f]/, " ")
           .squish
           .truncate(500)
    end

    def supplemental_report_type(extension)
      extension.in?(%w[.pdf .jpg .jpeg .png]) ? "supplemental_evidence" : "unclassified_spreadsheet"
    end

    def classify_report(title, filename)
      value = "#{title} #{filename}".downcase
      compact_value = value.gsub(/[^a-z0-9]/, "")
      return "payroll_details" if value.include?("payroll details")
      return "paycheck_history" if value.include?("paycheck history")
      return "employee_details" if value.include?("employee details")
      return "check_detail" if value.include?("check detail")
      return "payroll_summary_by_employee" if value.include?("payroll summary by employee")
      return "payroll_summary" if value.include?("payroll summary")
      return "tax_and_wage_summary" if value.include?("tax and wage summary")
      return "deductions_and_contributions" if value.include?("deductions") && value.include?("contributions")
      return "retirement_plans" if value.include?("retirement")
      return "payroll_tax_liability" if value.include?("tax liability")
      return "payroll_tax_payments" if value.include?("tax payments") || compact_value.include?("payrolltaxpayments")
      return "employee_directory" if value.include?("employee directory")
      return "time_off" if value.include?("time off") || compact_value.include?("timeoffreport")

      "unclassified_spreadsheet"
    end

    def parseable_report?(type)
      REQUIRED_REPORTS.include?(type) || type == "tax_and_wage_summary"
    end

    def parse_payroll_details(rows)
      header_index = rows.index { |row| row.map(&:to_s).include?("Gross pay - total") }
      raise ArgumentError, "Payroll Details headers were not found" unless header_index

      headers = rows.fetch(header_index).map { |header| header.to_s.squish }
      require_headers!(headers, "Payroll Details", [ "Name", "Pay date", "Time period", "Gross pay - total", "Net pay" ])
      paychecks = []
      signature_counts = Hash.new(0)
      rows.each_with_index.drop(header_index + 1).each do |row, zero_index|
        name = cell(row, headers, "Name").to_s.strip
        next if name.blank? || name.in?([ "Historical Checks", "Total" ])

        row_number = zero_index + 1
        pay_date = required_date(cell(row, headers, "Pay date"), "Payroll Details row #{row_number} Pay date")
        period_start, period_end = required_period(cell(row, headers, "Time period"), "Payroll Details row #{row_number} Time period")
        validate_date_order!(period_start, period_end, pay_date, "Payroll Details row #{row_number}")

        gross = money_cell(row, headers, "Gross pay - total", "Payroll Details", row_number)
        net = money_cell(row, headers, "Net pay", "Payroll Details", row_number)
        signature = paycheck_signature(name, pay_date, gross, net)
        signature_counts[signature] += 1
        paychecks << {
          external_key: paycheck_key(signature, signature_counts.fetch(signature)),
          source_row_number: zero_index + 1,
          source_employee_name: name,
          normalized_name: NameNormalizer.call(name),
          pay_date: pay_date,
          period_start: period_start,
          period_end: period_end,
          period_type: opening_summary?(period_start, period_end) ? "opening_summary" : "regular",
          payment_method: nil,
          check_number: nil,
          source_status: opening_summary?(period_start, period_end) ? "historical_summary" : "recorded",
          reconciliation_status: opening_summary?(period_start, period_end) ? "opening_summary" : "unmatched",
          hours_total: quantity_cell(row, headers, "Hours - total", "Payroll Details", row_number),
          gross_pay: gross,
          adjusted_gross: money_cell(row, headers, "Adjusted gross", "Payroll Details", row_number),
          pretax_deductions: -money_cell(row, headers, "Pretax deductions - total", "Payroll Details", row_number),
          employee_taxes: -money_cell(row, headers, "Employee taxes - total", "Payroll Details", row_number),
          federal_income_tax: -summed_money(row, headers, [ "Employee taxes - FIT", "Employee taxes - Federal Income Tax" ], "Payroll Details", row_number),
          social_security_tax: -summed_money(row, headers, [ "Employee taxes - SS", "Employee taxes - Social Security" ], "Payroll Details", row_number),
          medicare_tax: -summed_money(row, headers, [ "Employee taxes - Med", "Employee taxes - Medicare" ], "Payroll Details", row_number),
          after_tax_deductions: -money_cell(row, headers, "Employee Aftertax deductions - total", "Payroll Details", row_number),
          net_pay: net,
          employer_taxes: money_cell(row, headers, "Employer taxes - total", "Payroll Details", row_number),
          employer_contributions: money_cell(row, headers, "Company contributions - total", "Payroll Details", row_number),
          total_payroll_cost: money_cell(row, headers, "Total payroll cost", "Payroll Details", row_number),
          hours_breakdown: breakdown(row, headers, "Hours - ", exclude: [ "Hours - total" ], scale: 4, report: "Payroll Details", row_number: row_number),
          earnings_breakdown: breakdown(row, headers, "Gross pay - ", exclude: [ "Gross pay - total" ], report: "Payroll Details", row_number: row_number),
          pretax_deduction_breakdown: breakdown(row, headers, "Pretax deductions - ", exclude: [ "Pretax deductions - total" ], negate: true, report: "Payroll Details", row_number: row_number),
          after_tax_deduction_breakdown: breakdown(row, headers, "Employee Aftertax deductions - ", exclude: [ "Employee Aftertax deductions - total" ], negate: true, report: "Payroll Details", row_number: row_number),
          employee_tax_breakdown: breakdown(row, headers, "Employee taxes - ", exclude: [ "Employee taxes - total" ], negate: true, report: "Payroll Details", row_number: row_number),
          employer_tax_breakdown: breakdown(row, headers, "Employer taxes - ", exclude: [ "Employer taxes - total" ], report: "Payroll Details", row_number: row_number),
          employer_contribution_breakdown: breakdown(row, headers, "Company contributions - ", exclude: [ "Company contributions - total" ], report: "Payroll Details", row_number: row_number),
          source_metadata: {
            "time_period" => cell(row, headers, "Time period").to_s,
            "signature_occurrence" => signature_counts.fetch(signature)
          }
        }
      end
      raise ArgumentError, "Payroll Details did not contain paycheck rows" if paychecks.empty?

      { paychecks: paychecks }
    end

    def parse_paycheck_history(rows)
      header_index = rows.index { |row| row.map(&:to_s).include?("Check Number") && row.map(&:to_s).include?("Net pay") }
      raise ArgumentError, "Paycheck History headers were not found" unless header_index

      headers = rows.fetch(header_index).map { |header| header.to_s.squish }
      require_headers!(headers, "Paycheck History", [ "Pay date", "Name", "Total pay", "Net pay", "Check Number" ])
      signature_counts = Hash.new(0)
      rows.each_with_index.drop(header_index + 1).filter_map do |row, zero_index|
        name = cell(row, headers, "Name").to_s.strip
        next if name.blank? || name.in?([ "Historical Checks", "Total" ])

        row_number = zero_index + 1
        pay_date = required_date(cell(row, headers, "Pay date"), "Paycheck History row #{row_number} Pay date")
        gross = money_cell(row, headers, "Total pay", "Paycheck History", row_number)
        net = money_cell(row, headers, "Net pay", "Paycheck History", row_number)
        signature = paycheck_signature(name, pay_date, gross, net)
        signature_counts[signature] += 1
        {
          external_key: paycheck_key(signature, signature_counts.fetch(signature)),
          source_row_number: zero_index + 1,
          source_employee_name: name,
          pay_date: pay_date,
          gross_pay: gross,
          net_pay: net,
          payment_method: normalized_optional(cell(row, headers, "Pay method")),
          check_number: normalized_optional(cell(row, headers, "Check Number")),
          source_status: normalized_optional(cell(row, headers, "Status")) || "recorded"
        }
      end
    end

    def parse_payroll_summary(rows)
      header_index = rows.index { |row| row.map(&:to_s).include?("Total payroll cost") && row.map(&:to_s).include?("Net pay") }
      raise ArgumentError, "Payroll Summary headers were not found" unless header_index

      headers = rows.fetch(header_index).map { |header| header.to_s.squish }
      required = [ "Pay date", "Name", "Gross pay", "Pretax deductions", "Employee taxes", "Aftertax deduction", "Net pay", "Employer taxes", "Company contributions", "Total payroll cost" ]
      require_headers!(headers, "Payroll Summary", required)
      signature_counts = Hash.new(0)
      rows.each_with_index.drop(header_index + 1).filter_map do |row, zero_index|
        name = cell(row, headers, "Name").to_s.strip
        next if name.blank? || name.in?([ "Historical Checks", "Total" ])

        row_number = zero_index + 1
        pay_date = required_date(cell(row, headers, "Pay date"), "Payroll Summary row #{row_number} Pay date")
        gross = money_cell(row, headers, "Gross pay", "Payroll Summary", row_number)
        net = money_cell(row, headers, "Net pay", "Payroll Summary", row_number)
        signature = paycheck_signature(name, pay_date, gross, net)
        signature_counts[signature] += 1
        {
          external_key: paycheck_key(signature, signature_counts.fetch(signature)),
          source_row_number: row_number,
          source_employee_name: name,
          pay_date: pay_date,
          gross_pay: gross,
          pretax_deductions: -money_cell(row, headers, "Pretax deductions", "Payroll Summary", row_number),
          employee_taxes: -money_cell(row, headers, "Employee taxes", "Payroll Summary", row_number),
          after_tax_deductions: -money_cell(row, headers, "Aftertax deduction", "Payroll Summary", row_number),
          net_pay: net,
          employer_taxes: money_cell(row, headers, "Employer taxes", "Payroll Summary", row_number),
          employer_contributions: money_cell(row, headers, "Company contributions", "Payroll Summary", row_number),
          total_payroll_cost: money_cell(row, headers, "Total payroll cost", "Payroll Summary", row_number)
        }
      end
    end

    def reconcile_paycheck_history!(detail, history)
      history_by_key = history.index_by { |row| row.fetch(:external_key) }
      detail.fetch(:paychecks).each do |paycheck|
        next if paycheck.fetch(:period_type) == "opening_summary"

        match = history_by_key[paycheck.fetch(:external_key)]
        next unless match

        paycheck[:payment_method] = match.fetch(:payment_method)
        paycheck[:check_number] = match.fetch(:check_number)
        paycheck[:source_status] = match.fetch(:source_status)
        paycheck[:reconciliation_status] = "matched"
        paycheck[:source_metadata]["paycheck_history_row"] = match.fetch(:source_row_number)
      end
    end

    def reconcile_payroll_summary!(detail, summary_rows)
      summary_by_key = summary_rows.index_by { |row| row.fetch(:external_key) }
      detail.fetch(:paychecks).each do |paycheck|
        match = summary_by_key[paycheck.fetch(:external_key)]
        paycheck[:source_metadata]["payroll_summary_row"] = match.fetch(:source_row_number) if match
      end
    end

    def build_workers(paychecks, directory_rows, employee_rows)
      directory_header_index = directory_rows.index { |row| row.map(&:to_s).include?("Name") && row.map(&:to_s).include?("Hire date") }
      raise ArgumentError, "Employee Directory headers were not found" unless directory_header_index

      directory_headers = directory_rows.fetch(directory_header_index).map { |header| header.to_s.squish }
      require_headers!(directory_headers, "Employee Directory", [ "Name", "Hire date" ])
      source_workers = directory_rows.each_with_index.drop(directory_header_index + 1).filter_map do |row, zero_index|
        name = cell(row, directory_headers, "Name").to_s.strip
        next if name.blank? || name == "Total"

        normalized = NameNormalizer.call(name)
        raise ArgumentError, "Employee Directory row #{zero_index + 1} has an unusable employee name" if normalized.blank?

        [ normalized, {
          external_key: Digest::SHA256.hexdigest(normalized),
          source_name: name,
          normalized_name: normalized,
          source_status: name.start_with?("*") ? "inactive" : "active",
          hire_date: optional_date(cell(row, directory_headers, "Hire date"), "Employee Directory row #{zero_index + 1} Hire date"),
          source_row_number: zero_index + 1,
          directory_snapshot: directory_headers.each_with_index.to_h do |header, index|
            [ header, row[index].to_s.squish ]
          end
        } ]
      end
      duplicate_directory_names = source_workers.group_by(&:first).count { |_normalized, grouped| grouped.many? }
      raise ArgumentError, "#{duplicate_directory_names} normalized Employee Directory name collision(s) require manual source review" if duplicate_directory_names.positive?

      directory_by_name = source_workers.to_h
      missing_directory_workers = paychecks.map { |row| row.fetch(:normalized_name) }.uniq - directory_by_name.keys
      if missing_directory_workers.any?
        raise ArgumentError, "#{missing_directory_workers.size} Payroll Details worker(s) are missing from Employee Directory"
      end

      header_index = employee_rows.index { |row| row.map(&:to_s).include?("Personal info") }
      raise ArgumentError, "Employee Details headers were not found" unless header_index

      headers = employee_rows.fetch(header_index).map { |header| header.to_s.squish }
      require_headers!(headers, "Employee Details", [ "Personal info", "Hire date" ])
      source_names = source_workers.map { |_normalized, worker| worker.fetch(:source_name) }
      normalized_source_names = source_names.map { |name| [ name, NameNormalizer.call(name) ] }
      detail_rows = employee_rows.each_with_index.drop(header_index + 1).filter_map do |row, zero_index|
        personal_info = cell(row, headers, "Personal info").to_s.squish
        next if personal_info.blank?

        normalized_personal_info = NameNormalizer.call(personal_info)
        source_name = normalized_source_names
                      .select { |_name, normalized| normalized_personal_info.start_with?(normalized) }
                      .max_by { |name, _normalized| name.length }
                      &.first
        next unless source_name

        snapshot = headers.each_with_index.to_h do |header, index|
          [ header, row[index].to_s.squish ]
        end
        [ NameNormalizer.call(source_name), {
          source_row_number: zero_index + 1,
          hire_date: optional_date(cell(row, headers, "Hire date"), "Employee Details row #{zero_index + 1} Hire date"),
          private_snapshot: snapshot
        } ]
      end
      duplicate_detail_names = detail_rows.group_by(&:first).count { |_normalized, grouped| grouped.many? }
      raise ArgumentError, "#{duplicate_detail_names} normalized Employee Details name collision(s) require manual source review" if duplicate_detail_names.positive?

      details = detail_rows.to_h

      missing_details = directory_by_name.keys - details.keys
      extra_details = details.keys - directory_by_name.keys
      raise ArgumentError, "#{missing_details.size} Employee Directory worker(s) are missing from Employee Details" if missing_details.any?
      raise ArgumentError, "#{extra_details.size} Employee Details worker(s) are missing from Employee Directory" if extra_details.any?

      source_workers.sort_by(&:first).map do |normalized, worker|
        detail = details.fetch(normalized)
        worker.merge(
          hire_date: detail[:hire_date] || worker[:hire_date],
          private_snapshot: detail.fetch(:private_snapshot).merge(
            "_employee_directory" => worker.fetch(:directory_snapshot)
          ),
          details_source_row_number: detail.fetch(:source_row_number)
        ).except(:directory_snapshot)
      end
    end

    def build_periods(paychecks)
      paychecks.group_by { |row| PeriodKey.call(row) }.map do |key, rows|
        first = rows.first
        {
          external_key: key,
          period_type: first.fetch(:period_type),
          start_date: first.fetch(:period_start),
          end_date: first.fetch(:period_end),
          pay_date: first.fetch(:pay_date),
          source_label: "#{first.fetch(:period_start).strftime('%m/%d/%Y')} - #{first.fetch(:period_end).strftime('%m/%d/%Y')}",
          paycheck_count: rows.size,
          totals: money_totals(rows)
        }
      end.sort_by { |period| [ period.fetch(:pay_date), period.fetch(:start_date) ] }
    end

    def build_reconciliation(paychecks, history, payroll_summary)
      native = paychecks.reject { |row| row.fetch(:period_type) == "opening_summary" }
      matched = native.select { |row| row.fetch(:reconciliation_status) == "matched" }
      unmatched_details = native.reject { |row| row.fetch(:reconciliation_status) == "matched" }
      detail_keys = native.index_by { |row| row.fetch(:external_key) }
      unmatched_history = history.reject { |row| detail_keys.key?(row.fetch(:external_key)) }
      detail_totals = money_totals(native)
      history_totals = {
        "gross_pay" => sum(history, :gross_pay).to_s("F"),
        "net_pay" => sum(history, :net_pay).to_s("F")
      }
      summary_fields = %i[gross_pay pretax_deductions employee_taxes after_tax_deductions net_pay employer_taxes employer_contributions total_payroll_cost]
      all_detail_totals = money_totals(paychecks)
      summary_totals = summary_fields.to_h { |field| [ field.to_s, sum(payroll_summary, field).to_s("F") ] }
      all_detail_by_key = paychecks.index_by { |row| row.fetch(:external_key) }
      summary_by_key = payroll_summary.index_by { |row| row.fetch(:external_key) }
      unmatched_summary_details = paychecks.reject { |row| summary_by_key.key?(row.fetch(:external_key)) }
      unmatched_summary_rows = payroll_summary.reject { |row| all_detail_by_key.key?(row.fetch(:external_key)) }
      mismatched_summary_rows = paychecks.count do |row|
        match = summary_by_key[row.fetch(:external_key)]
        match && summary_fields.any? { |field| money(row.fetch(field)) != money(match.fetch(field)) }
      end
      errors = []
      duplicate_signature_groups = duplicate_signature_count(native) + duplicate_signature_count(history)
      if duplicate_signature_groups.positive?
        errors << "#{duplicate_signature_groups} duplicate paycheck signature group(s) require manual source review"
      end
      errors << "#{unmatched_details.size} native Payroll Details rows do not match Paycheck History" if unmatched_details.any?
      errors << "#{unmatched_history.size} Paycheck History rows do not match Payroll Details" if unmatched_history.any?
      errors << "Native gross pay does not reconcile between Payroll Details and Paycheck History" unless money(detail_totals.fetch("gross_pay")) == money(history_totals.fetch("gross_pay"))
      errors << "Native net pay does not reconcile between Payroll Details and Paycheck History" unless money(detail_totals.fetch("net_pay")) == money(history_totals.fetch("net_pay"))
      errors << "#{unmatched_summary_details.size} Payroll Details rows do not match Payroll Summary" if unmatched_summary_details.any?
      errors << "#{unmatched_summary_rows.size} Payroll Summary rows do not match Payroll Details" if unmatched_summary_rows.any?
      errors << "#{mismatched_summary_rows} matched Payroll Summary rows disagree with Payroll Details" if mismatched_summary_rows.positive?
      summary_fields.each do |field|
        next if all_detail_totals.fetch(field.to_s) == summary_totals.fetch(field.to_s)

        errors << "#{field.to_s.humanize} does not reconcile between Payroll Details and Payroll Summary"
      end

      {
        "passed" => errors.empty?,
        "payroll_detail_rows" => paychecks.size,
        "native_paycheck_rows" => native.size,
        "opening_summary_rows" => paychecks.size - native.size,
        "paycheck_history_rows" => history.size,
        "payroll_summary_rows" => payroll_summary.size,
        "matched_native_rows" => matched.size,
        "matched_summary_rows" => paychecks.size - unmatched_summary_details.size,
        "unmatched_detail_rows" => unmatched_details.size,
        "unmatched_history_rows" => unmatched_history.size,
        "unmatched_summary_detail_rows" => unmatched_summary_details.size,
        "unmatched_summary_rows" => unmatched_summary_rows.size,
        "mismatched_summary_rows" => mismatched_summary_rows,
        "native_detail_totals" => detail_totals,
        "paycheck_history_totals" => history_totals,
        "payroll_summary_totals" => summary_totals,
        "errors" => errors
      }
    end

    TAX_LINE_LABELS = {
      "federal income tax" => "federal_income_tax",
      "social security" => "social_security",
      "social security employer" => "social_security_employer",
      "medicare" => "medicare",
      "medicare employer" => "medicare_employer",
      "futa employer" => "futa_employer"
    }.freeze
    REQUIRED_TAX_LINES = %w[
      federal_income_tax social_security social_security_employer medicare medicare_employer
    ].freeze
    # These labels are the reviewed boundary between taxable and excluded historical wages.
    # Unmatched earnings remain taxable. NON_TAXABLE_EARNING_LABEL affects FIT and FICA;
    # FICA_EXEMPT_PRETAX_DEDUCTION_LABEL affects only FICA because FIT already subtracts
    # all pre-tax deductions. Expanding either pattern changes reconciliation and persisted
    # YTD balances and requires payroll review.
    NON_TAXABLE_EARNING_LABEL = /\A(?:(?:auto\s+(?:insurance|loan)\s+)?reimb(?:ursement|ursem)?|medicare\s+reimb\s+diffe|(?:rent|allotment)(?:\s*[-–—(].*)?|loan(?:\s*[-–—(].*|\s+pay\s+to\b.*)?)\z/i
    FICA_EXEMPT_PRETAX_DEDUCTION_LABEL = /\bsection\s*125\b|\bcafeteria\b|\b(?:health|medical|dental|vision)\b.*\bpre.?tax\b/i
    def parse_tax_wage_report(entry, position:)
      rows = entry.fetch(:rows)
      header_index = rows.index { |row| row.map { |cell| cell.to_s.squish }.include?("Tax types") }
      raise ArgumentError, "#{entry.fetch(:filename)} is missing Tax and Wage Summary headers" unless header_index

      range_text = rows.first(header_index).flatten.compact.map(&:to_s).find { |value| value.match?(/From .+ to .+ from all locations/i) }
      dates = range_text.to_s.scan(/[A-Z][a-z]{2} \d{1,2}, \d{4}/).map { |value| Date.strptime(value, "%b %d, %Y") }
      raise ArgumentError, "#{entry.fetch(:filename)} is missing its reporting period" unless dates.size == 2

      period_start, period_end = dates
      headers = rows.fetch(header_index).map { |header| header.to_s.squish }
      required_headers = [ "Tax types", "Total wages", "Excess wages", "Taxable wages", "Tax amount" ]
      require_headers!(headers, "#{entry.fetch(:filename)} Tax and Wage Summary", required_headers)
      tax_lines = rows.drop(header_index + 1).each_with_object({}) do |row, lines|
        label = cell(row, headers, "Tax types").to_s.squish
        next if label.blank?

        key = tax_line_key(label)
        if lines.key?(key)
          existing_label = lines.fetch(key).fetch("source_label")
          raise ArgumentError, "#{entry.fetch(:filename)} reports the same tax line twice: #{existing_label} and #{label}"
        end

        lines[key] = {
          "source_label" => label,
          "total_wages" => money(cell(row, headers, "Total wages"), context: "#{entry.fetch(:filename)} #{label} total wages").to_s("F"),
          "excess_wages" => money(cell(row, headers, "Excess wages"), context: "#{entry.fetch(:filename)} #{label} excess wages").to_s("F"),
          "taxable_wages" => money(cell(row, headers, "Taxable wages"), context: "#{entry.fetch(:filename)} #{label} taxable wages").to_s("F"),
          "tax_amount" => money(cell(row, headers, "Tax amount"), context: "#{entry.fetch(:filename)} #{label} tax amount").to_s("F")
        }
      end
      scope = tax_report_scope(entry.fetch(:filename), period_start, period_end)
      payload = {
        filename: entry.fetch(:filename),
        source_position: position,
        company_name: entry.fetch(:company_name),
        scope: scope,
        period_start: period_start,
        period_end: period_end,
        tax_lines: tax_lines
      }
      report_content = payload.except(:filename, :source_position)
      payload.merge(report_digest: Digest::SHA256.hexdigest(JSON.generate(canonical_digest_value(report_content))))
    rescue Date::Error
      raise ArgumentError, "#{entry.fetch(:filename)} has an invalid reporting period"
    end

    def tax_report_scope(filename, period_start, period_end)
      return "multi_year" if period_start.year != period_end.year
      quarter_start = Date.new(period_start.year, (((period_start.month - 1) / 3) * 3) + 1, 1)
      quarter_end = quarter_start.next_month(3) - 1.day
      if period_start == Date.new(period_start.year, 1, 1) && period_end == Date.new(period_start.year, 3, 31)
        return "quarterly_year_to_date"
      end
      return "quarterly" if period_start == quarter_start && period_end == quarter_end
      return "annual" if period_start == Date.new(period_start.year, 1, 1) && period_end == Date.new(period_end.year, 12, 31)
      return "quarterly" if filename.match?(/(?:\A|[\s_-])Q[1-4](?:\z|[\s_.-])/i)

      "year_to_date"
    end

    def tax_line_key(label)
      TAX_LINE_LABELS[label.downcase] ||
        ("state_unemployment_employer" if label.match?(/\A(?:[A-Z]{2}|Guam) Unemployment Insurance Tax Employer\z/i)) ||
        "unmapped_#{Digest::SHA256.hexdigest(label.downcase)[0, 16]}"
    end

    def build_tax_wage_reconciliation(paychecks, reports, company_name:, parse_errors: [])
      if reports.empty?
        return {
          "passed" => false,
          "report_count" => 0,
          "checks" => [],
          "errors" => parse_errors,
          "not_available" => parse_errors.empty?
        }
      end

      errors = parse_errors.dup
      checks = []
      handled_source_positions = {}
      authoritative_by_year = {}
      normalized_company = NameNormalizer.call(company_name)
      reports.each do |report|
        next if NameNormalizer.call(report.fetch(:company_name)) == normalized_company

        errors << "#{report.fetch(:filename)} names a different company than the required QuickBooks reports"
      end
      reports.group_by { |report| [ report.fetch(:period_start), report.fetch(:period_end) ] }
             .select { |_period, grouped| grouped.many? }
             .each_key do |period_start, period_end|
        errors << "Tax and Wage Summary reporting period #{period_start.strftime('%m/%d/%Y')} through #{period_end.strftime('%m/%d/%Y')} was supplied more than once"
      end

      paychecks.group_by { |row| row.fetch(:pay_date).year }.sort.each do |year, year_rows|
        authoritative = reports.select do |report|
          report.fetch(:period_start) == Date.new(year, 1, 1) &&
            report.fetch(:period_end).year == year &&
            report.fetch(:scope).in?(%w[annual year_to_date quarterly_year_to_date])
        end.max_by { |report| report.fetch(:period_end) }
        unless authoritative
          errors << "Missing authoritative #{year} Tax and Wage Summary"
          next
        end
        authoritative_by_year[year] = authoritative
        handled_source_positions[authoritative.fetch(:source_position)] = true
        if authoritative.fetch(:period_end) < year_rows.map { |row| row.fetch(:pay_date) }.max
          errors << "#{authoritative.fetch(:filename)} ends before the final #{year} paycheck"
          next
        end

        missing_lines = REQUIRED_TAX_LINES - authoritative.fetch(:tax_lines).keys
        if missing_lines.any?
          errors << "#{authoritative.fetch(:filename)} is missing required tax line(s): #{missing_lines.join(', ')}"
          next
        end

        ss_wage_base = social_security_wage_base(year)
        unless ss_wage_base
          errors << "No Social Security wage base is configured for #{year}; add the annual tax configuration before accepting this history"
          next
        end

        derived = derived_tax_wage_totals(year_rows, ss_wage_base: ss_wage_base)
        year_checks = tax_wage_checks(authoritative.fetch(:tax_lines), derived)
        checks.concat(year_checks.map do |check|
          check.merge(
            "year" => year,
            "source" => authoritative.fetch(:filename),
            "social_security_wage_base" => ss_wage_base.to_s("F")
          )
        end)
        year_checks.reject { |check| check.fetch("passed") }.each do |check|
          errors << "#{year} #{check.fetch('label')} does not match the Tax and Wage Summary"
        end

        quarter_reports = reports.select do |report|
          report.fetch(:scope).in?(%w[quarterly quarterly_year_to_date]) && report.fetch(:period_start).year == year &&
            report.fetch(:period_end) <= authoritative.fetch(:period_end) &&
            report.fetch(:source_position) != authoritative.fetch(:source_position)
        end
        next if authoritative.fetch(:scope) == "quarterly_year_to_date" && quarter_reports.empty?
        quarter_ends = [
          Date.new(year, 3, 31),
          Date.new(year, 6, 30),
          Date.new(year, 9, 30),
          Date.new(year, 12, 31)
        ]
        completed_quarter_end = quarter_ends.select { |quarter_end| quarter_end <= authoritative.fetch(:period_end) }.max
        partial_quarter = quarter_reports.find { |report| report.fetch(:period_end) == authoritative.fetch(:period_end) }
        rollup_end = partial_quarter ? authoritative.fetch(:period_end) : completed_quarter_end
        required_quarters = rollup_end ? ((rollup_end.month - 1) / 3) + 1 : 0
        quarter_reports = quarter_reports.select { |report| rollup_end && report.fetch(:period_end) <= rollup_end }
        quarter_reports.each { |report| handled_source_positions[report.fetch(:source_position)] = true }
        quarter_groups = quarter_reports.group_by { |report| ((report.fetch(:period_start).month - 1) / 3) + 1 }
        duplicate_quarters = quarter_groups.select { |_quarter, grouped| grouped.many? }.keys.sort
        if duplicate_quarters.any?
          checks << failed_quarterly_check(year, authoritative, "Quarterly tax-and-wage evidence has one report per quarter")
          errors << "#{year} has more than one Tax and Wage Summary for Q#{duplicate_quarters.join(', Q')}"
          next
        end
        quarter_numbers = quarter_groups.keys.sort
        required_quarter_numbers = (1..required_quarters).to_a
        unless (required_quarter_numbers - quarter_numbers).empty?
          checks << failed_quarterly_check(year, authoritative, "Quarterly tax-and-wage reports include every completed quarter")
          errors << "#{year} Tax and Wage Summary is missing one or more quarterly reports through Q#{required_quarters}"
          next
        end
        next if required_quarters.zero?

        rollup_reports = quarter_groups.values.map(&:first)
        unless quarterly_coverage_complete?(rollup_reports, through_date: rollup_end)
          checks << failed_quarterly_check(year, authoritative, "Quarterly tax-and-wage reports cover the authoritative period without gaps")
          errors << "#{year} quarterly Tax and Wage Summary reports do not cover the authoritative year report contiguously"
          next
        end

        quarter_check = if rollup_end == authoritative.fetch(:period_end)
          quarterly_tax_reports_match?(rollup_reports, authoritative)
        else
          completed_rows = year_rows.select { |row| row.fetch(:pay_date) <= rollup_end }
          quarterly_tax_reports_match_derived?(
            rollup_reports,
            derived_tax_wage_totals(completed_rows, ss_wage_base: ss_wage_base)
          )
        end
        checks << {
          "key" => "#{year}_quarterly_rollup",
          "year" => year,
          "label" => "Quarterly tax-and-wage reports sum to the authoritative year report",
          "source" => authoritative.fetch(:filename),
          "passed" => quarter_check
        }
        errors << "#{year} quarterly Tax and Wage Summary reports do not sum to the authoritative year report" unless quarter_check
      end

      reports.select { |report| report.fetch(:scope) == "multi_year" }.each do |report|
        handled_source_positions[report.fetch(:source_position)] = true
        sources = authoritative_by_year.values.select do |source|
          source.fetch(:period_start) >= report.fetch(:period_start) &&
            source.fetch(:period_end) <= report.fetch(:period_end)
        end.sort_by { |source| source.fetch(:period_start) }
        expected_start = report.fetch(:period_start)
        contiguous = sources.any? && sources.all? do |source|
          matches = source.fetch(:period_start) == expected_start
          expected_start = source.fetch(:period_end) + 1.day
          matches
        end && expected_start == report.fetch(:period_end) + 1.day
        matches = contiguous && tax_reports_sum_to_report?(sources, report)
        checks << {
          "key" => "multi_year_rollup_#{report.fetch(:period_start).iso8601}_#{report.fetch(:period_end).iso8601}",
          "label" => "Annual and YTD tax-and-wage reports sum to the multi-year report",
          "source" => report.fetch(:filename),
          "passed" => matches
        }
        errors << "#{report.fetch(:filename)} is not fully reconciled by the authoritative annual and YTD reports" unless matches
      end

      paycheck_years = paychecks.map { |row| row.fetch(:pay_date).year }.uniq
      reports.reject { |report| handled_source_positions[report.fetch(:source_position)] }.each do |report|
        covered_years = (report.fetch(:period_start).year..report.fetch(:period_end).year)
        errors << if covered_years.none? { |year| paycheck_years.include?(year) }
          "#{report.fetch(:filename)} reporting period contains no imported QuickBooks paychecks"
        else
          "#{report.fetch(:filename)} is not associated with a reconciled QuickBooks payroll year or reporting window"
        end
      end

      {
        "passed" => errors.empty?,
        "report_count" => reports.size,
        "checks" => checks,
        "errors" => errors,
        "not_available" => false
      }
    end

    def tax_wage_checks(lines, derived)
      expected = {
        "fit_total_wages" => [ "FIT total wages", lines.dig("federal_income_tax", "total_wages"), derived.fetch("fit_taxable_wages") ],
        "fit_tax" => [ "Federal income tax withheld", lines.dig("federal_income_tax", "tax_amount"), derived.fetch("federal_income_tax") ],
        "ss_total_wages" => [ "Social Security total wages", lines.dig("social_security", "total_wages"), derived.fetch("fica_total_wages") ],
        "ss_excess_wages" => [ "Social Security excess wages", lines.dig("social_security", "excess_wages"), derived.fetch("social_security_excess_wages") ],
        "ss_taxable_wages" => [ "Social Security taxable wages", lines.dig("social_security", "taxable_wages"), derived.fetch("social_security_taxable_wages") ],
        "ss_tax" => [ "Social Security tax withheld", lines.dig("social_security", "tax_amount"), derived.fetch("social_security_tax") ],
        "employer_ss_tax" => [ "Employer Social Security tax", lines.dig("social_security_employer", "tax_amount"), derived.fetch("employer_social_security_tax") ],
        "medicare_wages" => [ "Medicare taxable wages", lines.dig("medicare", "taxable_wages"), derived.fetch("medicare_taxable_wages") ],
        "medicare_tax" => [ "Medicare tax withheld", lines.dig("medicare", "tax_amount"), derived.fetch("medicare_tax") ],
        "employer_medicare_tax" => [ "Employer Medicare tax", lines.dig("medicare_employer", "tax_amount"), derived.fetch("employer_medicare_tax") ]
      }
      expected.map do |key, (label, source, calculated)|
        {
          "key" => key,
          "label" => label,
          "source_amount" => money(source).to_s("F"),
          "calculated_amount" => money(calculated).to_s("F"),
          "passed" => money(source) == money(calculated)
        }
      end
    end

    def derived_tax_wage_totals(rows, ss_wage_base:)
      wages = WageDerivation.call(
        rows: rows.map do |row|
          {
            employee_key: row.fetch(:normalized_name),
            gross_pay: row.fetch(:gross_pay),
            pretax_deductions: row.fetch(:pretax_deductions),
            non_taxable_earnings: non_taxable_earnings(row),
            fica_exempt_pretax_deductions: fica_exempt_pretax_deductions(row)
          }
        end,
        social_security_wage_base: ss_wage_base
      )
      {
        "fit_taxable_wages" => wages.fetch(:fit_taxable_wages),
        "fica_total_wages" => wages.fetch(:fica_total_wages),
        "social_security_excess_wages" => wages.fetch(:social_security_excess_wages),
        "social_security_taxable_wages" => wages.fetch(:social_security_taxable_wages),
        "medicare_taxable_wages" => wages.fetch(:medicare_taxable_wages),
        "federal_income_tax" => rows.sum(0.to_d) { |row| row.fetch(:federal_income_tax) }.round(2),
        "social_security_tax" => rows.sum(0.to_d) { |row| row.fetch(:social_security_tax) }.round(2),
        "medicare_tax" => rows.sum(0.to_d) { |row| row.fetch(:medicare_tax) }.round(2),
        "employer_social_security_tax" => breakdown_total(rows, :employer_tax_breakdown, /\A(?:SS|Social Security(?: Employer)?)\z/i),
        "employer_medicare_tax" => breakdown_total(rows, :employer_tax_breakdown, /\A(?:Med|Medicare(?: Employer)?)\z/i)
      }
    end

    def non_taxable_earnings(row)
      Array(row.fetch(:earnings_breakdown)).sum(0.to_d) do |entry|
        non_taxable_earning_label?(entry.fetch("label")) ? money(entry.fetch("amount")) : 0.to_d
      end.round(2)
    end

    def non_taxable_earning_label?(label)
      label.to_s.squish.match?(NON_TAXABLE_EARNING_LABEL)
    end

    def fica_exempt_pretax_deductions(row)
      Array(row.fetch(:pretax_deduction_breakdown)).sum(0.to_d) do |entry|
        entry.fetch("label").match?(FICA_EXEMPT_PRETAX_DEDUCTION_LABEL) ? money(entry.fetch("amount")) : 0.to_d
      end.round(2)
    end

    def social_security_wage_base(year)
      AnnualTaxConfig.historical_ss_wage_base(year)
    end

    def breakdown_total(rows, field, label_pattern)
      rows.sum(0.to_d) do |row|
        Array(row.fetch(field)).sum(0.to_d) do |entry|
          entry.fetch("label").match?(label_pattern) ? money(entry.fetch("amount")) : 0.to_d
        end
      end.round(2)
    end

    def quarterly_tax_reports_match?(quarters, authoritative)
      tax_reports_sum_to_report?(quarters, authoritative)
    end

    def tax_reports_sum_to_report?(reports, authoritative)
      REQUIRED_TAX_LINES.all? do |line|
        %w[total_wages excess_wages taxable_wages tax_amount].all? do |field|
          source = money(authoritative.dig(:tax_lines, line, field))
          total = reports.sum(0.to_d) { |report| money(report.dig(:tax_lines, line, field)) }
          source == total.round(2)
        end
      end
    end

    def quarterly_coverage_complete?(quarters, through_date:)
      expected_start = Date.new(through_date.year, 1, 1)
      # all? advances the expected start through the entire contiguous sequence;
      # only a complete pass makes the trailing authoritative-end comparison meaningful.
      quarters.sort_by { |report| report.fetch(:period_start) }.all? do |report|
        contiguous = report.fetch(:period_start) == expected_start
        expected_start = report.fetch(:period_end) + 1.day
        contiguous
      end && expected_start == through_date + 1.day
    end

    def quarterly_tax_reports_match_derived?(quarters, derived)
      comparisons = {
        [ "federal_income_tax", "total_wages" ] => "fit_taxable_wages",
        [ "federal_income_tax", "tax_amount" ] => "federal_income_tax",
        [ "social_security", "total_wages" ] => "fica_total_wages",
        [ "social_security", "excess_wages" ] => "social_security_excess_wages",
        [ "social_security", "taxable_wages" ] => "social_security_taxable_wages",
        [ "social_security", "tax_amount" ] => "social_security_tax",
        [ "social_security_employer", "tax_amount" ] => "employer_social_security_tax",
        [ "medicare", "taxable_wages" ] => "medicare_taxable_wages",
        [ "medicare", "tax_amount" ] => "medicare_tax",
        [ "medicare_employer", "tax_amount" ] => "employer_medicare_tax"
      }
      comparisons.all? do |(line, field), derived_key|
        source = quarters.sum(0.to_d) { |report| money(report.dig(:tax_lines, line, field)) }.round(2)
        source == money(derived.fetch(derived_key))
      end
    end

    def failed_quarterly_check(year, authoritative, label)
      {
        "key" => "#{year}_quarterly_rollup",
        "year" => year,
        "label" => label,
        "source" => authoritative.fetch(:filename),
        "passed" => false
      }
    end

    def canonical_digest_value(value)
      CanonicalJson.normalize(value)
    end

    def build_warnings(paychecks, history, inventory, tax_wage_reports:)
      opening_rows = paychecks.select { |row| row.fetch(:period_type) == "opening_summary" }
      opening_count = opening_rows.size
      missing_check_numbers = history.count { |row| row[:check_number].blank? }
      warnings = []
      if opening_count.positive?
        opening_start = opening_rows.map { |row| row.fetch(:period_start) }.min
        opening_end = opening_rows.map { |row| row.fetch(:period_end) }.max
        warnings << "#{opening_count} employee opening-balance rows summarize #{opening_start.strftime('%m/%d/%Y')} through #{opening_end.strftime('%m/%d/%Y')}. They preserve QuickBooks totals but are not original paycheck-level periods."
      end
      warnings << "#{missing_check_numbers} QuickBooks paychecks have no accounting check number in Paycheck History." if missing_check_numbers.positive?
      unreadable = inventory.select { |entry| entry[:report_type] == "unreadable_spreadsheet" }
      if unreadable.any?
        warnings << "Supplemental spreadsheet(s) could not be parsed: #{unreadable.map { |entry| entry.fetch(:filename) }.join(', ')}. They remain fingerprinted as source evidence."
      end
      # IRS Publication 15 section 14 excludes Guam employers from FUTA.
      # Keep imported evidence intact, but require review instead of silently
      # treating a QuickBooks FUTA line as a Guam liability.
      reports_with_futa = tax_wage_reports.select do |report|
        money(report.dig(:tax_lines, "futa_employer", "tax_amount")).nonzero?
      end
      if reports_with_futa.any?
        warnings << "QuickBooks reports non-zero FUTA employer tax. FUTA generally does not apply to Guam employers; obtain payroll-review approval before activating this history."
      end
      warnings
    end

    def build_summary(paychecks, workers, periods, inventory)
      totals = money_totals(paychecks)
      {
        "file_count" => inventory.size,
        "worker_count" => workers.size,
        "period_count" => periods.size,
        "paycheck_count" => paychecks.size,
        "first_pay_date" => paychecks.map { |row| row.fetch(:pay_date) }.min.iso8601,
        "last_pay_date" => paychecks.map { |row| row.fetch(:pay_date) }.max.iso8601,
        "opening_summary_count" => paychecks.count { |row| row.fetch(:period_type) == "opening_summary" },
        "check_number_count" => paychecks.count { |row| row[:check_number].present? },
        "totals" => totals
      }
    end

    def money_totals(rows)
      ImportService::MONEY_FIELDS.to_h do |field|
        [ field.to_s, sum(rows, field).to_s("F") ]
      end
    end

    def paycheck_signature(name, pay_date, gross, net)
      [ NameNormalizer.call(name), pay_date.iso8601, gross.to_s("F"), net.to_s("F") ].join("|")
    end

    def paycheck_key(signature, occurrence)
      Digest::SHA256.hexdigest("#{signature}|#{occurrence}")
    end

    def duplicate_signature_count(rows)
      rows.group_by do |row|
        paycheck_signature(row.fetch(:source_employee_name), row.fetch(:pay_date), row.fetch(:gross_pay), row.fetch(:net_pay))
      end.count { |_signature, grouped| grouped.many? }
    end

    def validate_distinct_worker_names!(paychecks)
      collisions = paychecks.group_by { |row| row.fetch(:normalized_name) }
                           .count { |_normalized, rows| rows.map { |row| row.fetch(:source_employee_name) }.uniq.many? }
      return if collisions.zero?

      raise ArgumentError, "#{collisions} normalized employee name collision(s) require manual source review"
    end

    def opening_summary?(start_date, end_date)
      (end_date - start_date).to_i > 45
    end

    def validate_date_order!(period_start, period_end, pay_date, context)
      raise ArgumentError, "#{context} period end must be on or after period start" if period_end < period_start
      raise ArgumentError, "#{context} pay date must be on or after period end" if pay_date < period_end
    end

    def validate_record_counts!(workers, periods, paychecks)
      raise ArgumentError, "QuickBooks bundle exceeds #{MAX_WORKER_COUNT.to_fs(:delimited)} workers" if workers.size > MAX_WORKER_COUNT
      raise ArgumentError, "QuickBooks bundle exceeds #{MAX_PERIOD_COUNT.to_fs(:delimited)} pay periods" if periods.size > MAX_PERIOD_COUNT
      raise ArgumentError, "QuickBooks bundle exceeds #{MAX_PAYCHECK_COUNT.to_fs(:delimited)} paychecks" if paychecks.size > MAX_PAYCHECK_COUNT
    end

    def breakdown(row, headers, prefix, exclude:, report:, row_number:, negate: false, scale: 2)
      headers.each_with_index.filter_map do |header, index|
        next unless header.start_with?(prefix)
        next if exclude.include?(header)

        amount = decimal(row[index], scale: scale, context: "#{report} row #{row_number} #{header}")
        amount = -amount if negate
        next if amount.zero?

        { "label" => header.delete_prefix(prefix), "amount" => amount.to_s("F") }
      end
    end

    def summed_money(row, headers, names, report, row_number)
      names.sum(0.to_d) { |name| money(cell(row, headers, name), context: "#{report} row #{row_number} #{name}") }
    end

    def cell(row, headers, name)
      index = headers.index(name)
      index ? row[index] : nil
    end

    def money(value, context: nil)
      decimal(value, scale: 2, context: context)
    end

    def quantity(value, context: nil)
      decimal(value, scale: 4, context: context)
    end

    def decimal(value, scale:, context: nil)
      return value.to_d.round(scale) if value.respond_to?(:to_d) && !value.is_a?(String)

      normalized = value.to_s.strip.gsub(/[,$]/, "")
      return 0.to_d if normalized.blank? || normalized == "-"
      return -BigDecimal(normalized.delete_prefix("(").delete_suffix(")")).round(scale) if normalized.start_with?("(") && normalized.end_with?(")")

      BigDecimal(normalized).round(scale)
    rescue ArgumentError
      raise ArgumentError, "#{context || 'QuickBooks numeric value'} is not a valid number"
    end

    def money_cell(row, headers, name, report, row_number)
      money(cell(row, headers, name), context: "#{report} row #{row_number} #{name}")
    end

    def quantity_cell(row, headers, name, report, row_number)
      quantity(cell(row, headers, name), context: "#{report} row #{row_number} #{name}")
    end

    def sum(rows, field)
      rows.sum(0.to_d) { |row| money(row.fetch(field, 0)) }.round(2)
    end

    def parse_date(value)
      return value.to_date if value.respond_to?(:to_date) && !value.is_a?(String)

      Date.strptime(value.to_s.strip, "%m/%d/%Y")
    rescue ArgumentError
      nil
    end

    def required_date(value, context)
      parse_date(value) || raise(ArgumentError, "#{context} is missing or invalid")
    end

    def optional_date(value, context)
      return nil if value.to_s.strip.blank? || value.to_s.strip == "-"

      parse_date(value) || raise(ArgumentError, "#{context} is invalid")
    end

    def required_period(value, context)
      start_date, end_date = parse_period(value)
      raise ArgumentError, "#{context} is missing or invalid" unless start_date && end_date

      [ start_date, end_date ]
    end

    def require_headers!(headers, report, required)
      missing = required - headers
      raise ArgumentError, "#{report} is missing required column(s): #{missing.join(', ')}" if missing.any?
    end

    def parse_period(value)
      matches = value.to_s.scan(/\d{2}\/\d{2}\/\d{4}/)
      [ parse_date(matches[0]), parse_date(matches[1]) ]
    end

    def normalized_optional(value)
      text = value.to_s.strip
      text.present? && text != "-" ? text : nil
    end

    def empty_result(bundle_digest, inventory, errors)
      Result.new(
        bundle_digest: bundle_digest,
        company_name: inventory.filter_map { |entry| entry[:company_name] }.first || "QuickBooks company",
        source_label: "Incomplete QuickBooks history bundle",
        manifest: inventory.each_with_index.map { |entry, position| entry.except(:rows).merge(position: position) },
        workers: [],
        periods: [],
        paychecks: [],
        summary: { "file_count" => inventory.size, "worker_count" => 0, "period_count" => 0, "paycheck_count" => 0, "totals" => {} },
        reconciliation: { "passed" => false, "errors" => errors },
        tax_wage_reports: [],
        tax_wage_reconciliation: {
          "passed" => false,
          "report_count" => 0,
          "checks" => [],
          "errors" => [],
          "not_available" => inventory.none? { |entry| entry[:report_type] == "tax_and_wage_summary" }
        },
        warnings: [],
        errors: errors,
        source_files: files
      )
    end
  end
end
