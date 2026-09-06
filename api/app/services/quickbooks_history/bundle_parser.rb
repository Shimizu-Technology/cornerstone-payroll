# frozen_string_literal: true

require "digest"

module QuickbooksHistory
  class BundleParser
    IMPORTER_VERSION = "quickbooks-online-payroll-v2"
    REQUIRED_REPORTS = %w[
      payroll_details paycheck_history payroll_summary employee_details employee_directory
    ].freeze
    MAX_FILE_COUNT = 75
    MAX_FILE_BYTES = 30.megabytes
    MAX_BUNDLE_BYTES = 150.megabytes
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
      :warnings,
      :errors,
      keyword_init: true
    )

    SourceFile = Struct.new(:original_filename, :path, :size, :source, keyword_init: true)

    def initialize(files:)
      @files = Array(files).map { |file| normalize_file(file) }
    end

    def call
      validate_bundle!
      inventory = files.map { |file| inventory_file(file) }
      bundle_digest = Digest::SHA256.hexdigest(inventory.sort_by { |entry| entry.fetch(:filename) }.map { |entry| "#{entry.fetch(:filename)}:#{entry.fetch(:sha256)}" }.join("\n"))
      report_entries = inventory.select { |entry| entry[:rows].present? }
      reports = report_entries.index_by { |entry| entry.fetch(:report_type) }
      missing = REQUIRED_REPORTS - reports.keys
      errors = missing.map { |type| "Missing required QuickBooks report: #{type.humanize}" }
      duplicate_required_reports(report_entries).each do |type|
        errors << "Multiple #{type.humanize} reports were supplied; upload one authoritative report of each required type"
      end
      required_entries = report_entries.select { |entry| REQUIRED_REPORTS.include?(entry.fetch(:report_type)) }
      errors << "Every required QuickBooks report must identify its company" if required_entries.any? { |entry| entry[:company_name].blank? }
      errors << "Required QuickBooks reports name more than one company" if multiple_source_companies?(report_entries)
      inventory.select { |entry| entry[:report_type] == "unreadable_spreadsheet" }.each do |entry|
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
      reconciliation = build_reconciliation(detail.fetch(:paychecks), history, payroll_summary)
      warnings = build_warnings(detail.fetch(:paychecks), history, inventory)
      company_name = inventory.find { |entry| entry[:report_type] == "payroll_details" }.fetch(:company_name)
      max_pay_date = detail.fetch(:paychecks).map { |row| row.fetch(:pay_date) }.max

      Result.new(
        bundle_digest: bundle_digest,
        company_name: company_name,
        source_label: "#{company_name} QuickBooks history through #{max_pay_date.iso8601}",
        manifest: inventory.map { |entry| entry.except(:rows) },
        workers: workers,
        periods: periods,
        paychecks: detail.fetch(:paychecks),
        summary: build_summary(detail.fetch(:paychecks), workers, periods, inventory),
        reconciliation: reconciliation,
        warnings: warnings,
        errors: reconciliation.fetch("errors")
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
      size = file.respond_to?(:size) ? file.size : File.size(path)
      # Keep the upload object alive while parsing. Rack may unlink its tempfile
      # when the uploaded-file wrapper is garbage collected.
      SourceFile.new(original_filename: filename, path: path, size: size, source: file)
    end

    def validate_bundle!
      raise ArgumentError, "Select at least one QuickBooks export file" if files.empty?
      raise ArgumentError, "A QuickBooks bundle can contain at most #{MAX_FILE_COUNT} files" if files.size > MAX_FILE_COUNT
      raise ArgumentError, "The QuickBooks bundle is larger than #{MAX_BUNDLE_BYTES / 1.megabyte} MB" if files.sum(&:size).to_i > MAX_BUNDLE_BYTES

      files.each do |file|
        extension = File.extname(file.original_filename.to_s).downcase
        raise ArgumentError, "Unsupported file type: #{extension.presence || 'unknown'}" unless ALLOWED_EXTENSIONS.include?(extension)
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

      begin
        rows = SpreadsheetReader.read(path: file.path, extension: extension)
        title = rows.first(6).flatten.compact.map(&:to_s).find { |value| value.downcase.include?("report") }.to_s
        report_type = classify_report(title, file.original_filename)
        entry.merge(
          report_type: report_type,
          company_name: rows.dig(0, 0).to_s.strip,
          row_count: rows.size,
          rows: parseable_report?(report_type) ? rows : nil
        )
      rescue StandardError
        entry.merge(report_type: "unreadable_spreadsheet", parse_error: "Spreadsheet could not be read")
      end
    end

    def safe_filename(file)
      File.basename(file.original_filename.to_s).gsub(/[\u0000-\u001f]/, "").truncate(240)
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
      REQUIRED_REPORTS.include?(type)
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
          source_row_number: zero_index + 1
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
          private_snapshot: detail.fetch(:private_snapshot),
          details_source_row_number: detail.fetch(:source_row_number)
        )
      end
    end

    def build_periods(paychecks)
      paychecks.group_by { |row| period_key(row) }.map do |key, rows|
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

    def build_warnings(paychecks, history, inventory)
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
      unreadable = inventory.count { |entry| entry[:report_type] == "unreadable_spreadsheet" }
      warnings << "#{unreadable} supplemental spreadsheet(s) could not be inventoried." if unreadable.positive?
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
      %i[gross_pay adjusted_gross pretax_deductions employee_taxes federal_income_tax social_security_tax medicare_tax after_tax_deductions net_pay employer_taxes employer_contributions total_payroll_cost].to_h do |field|
        [ field.to_s, sum(rows, field).to_s("F") ]
      end
    end

    def period_key(row)
      Digest::SHA256.hexdigest([ row.fetch(:period_start), row.fetch(:period_end), row.fetch(:pay_date), row.fetch(:period_type) ].join("|"))
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
        manifest: inventory.map { |entry| entry.except(:rows) },
        workers: [],
        periods: [],
        paychecks: [],
        summary: { "file_count" => inventory.size, "worker_count" => 0, "period_count" => 0, "paycheck_count" => 0, "totals" => {} },
        reconciliation: { "passed" => false, "errors" => errors },
        warnings: [],
        errors: errors
      )
    end
  end
end
