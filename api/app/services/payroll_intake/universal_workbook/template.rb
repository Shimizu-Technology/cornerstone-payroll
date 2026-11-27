# frozen_string_literal: true

require "caxlsx"
require "csv"

module PayrollIntake
  module UniversalWorkbook
    # Generates the per-pay-period Cornerstone universal payroll workbook in
    # both XLSX and CSV formats with identical payroll data columns.
    #
    # Every active employee is pre-filled with their stable Cornerstone
    # Employee ID (used for matching) and full name (readability only).
    class Template
      SCHEMA_VERSION = "cornerstone-universal-workbook/v1"
      START_SHEET = "START HERE"
      PAYROLL_SHEET = "PAYROLL"

      COLUMNS = [
        "Employee ID",
        "Employee",
        "Week 1 Hours",
        "Week 2 Hours",
        "Regular Hours",
        "Overtime Hours",
        "PTO Hours",
        "Holiday Hours",
        "Tips",
        "Tips Already Paid (YES/NO)",
        "Bonus",
        "One-Time Item Type",
        "One-Time Item Label",
        "One-Time Item Amount",
        "Loan Deduction",
        "Notes"
      ].freeze

      ONE_TIME_ITEM_TYPES = PayrollImport::LoanTipExcelParser::GENERATED_COMPONENT_TYPES.keys.freeze
      FORMULA_PREFIXES = %w[= + - @].freeze

      def initialize(pay_period: nil, company: nil, start_date: nil, end_date: nil, pay_date: nil)
        @pay_period = pay_period
        @company = company || pay_period&.company
        @start_date = (start_date || pay_period&.start_date)&.to_date
        @end_date = (end_date || pay_period&.end_date)&.to_date
        @pay_date = (pay_date || pay_period&.pay_date)&.to_date
        raise ArgumentError, "Company is required to generate the Cornerstone workbook template" unless @company
        raise ArgumentError, "Pay period start and end dates are required" unless @start_date && @end_date
      end

      def generate_xlsx
        package = Axlsx::Package.new
        workbook = package.workbook
        styles = build_styles(workbook)

        add_start_sheet(workbook, styles)
        add_payroll_sheet(workbook, styles)

        package.to_stream.read
      end
      alias_method :generate, :generate_xlsx

      def generate_csv
        CSV.generate(force_quotes: false) do |csv|
          csv << COLUMNS
          employees.each do |employee|
            csv << [
              employee.id,
              safe_csv_cell(employee.full_name),
              "", "", "", "", "", "", "", "", "", "", "", "", "", ""
            ]
          end
        end
      end

      def filename(format: :xlsx)
        ext = format.to_sym == :csv ? "csv" : "xlsx"
        slug = company.name.to_s.parameterize.presence || "client"
        "#{slug}-cornerstone-workbook-#{end_date.iso8601}.#{ext}"
      end

      def content_type(format: :xlsx)
        if format.to_sym == :csv
          "text/csv; charset=utf-8"
        else
          "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        end
      end

      private

      attr_reader :pay_period, :company, :start_date, :end_date, :pay_date

      def employees
        @employees ||= company.employees.active.order(:last_name, :first_name, :id).to_a
      end

      def effective_settings
        @effective_settings ||= PayrollIntake::EffectiveSettings.for(
          company: company,
          pay_period: pay_period,
          on: end_date,
          source_type: "cornerstone_workbook"
        )
      end

      def pay_frequency
        PayrollIntake::WorkweekEvidence.pay_frequency_for(
          pay_period: pay_period,
          company: company,
          start_date: start_date
        )
      end

      def build_styles(workbook)
        {
          title: workbook.styles.add_style(bg_color: "17324D", fg_color: "FFFFFF", b: true, sz: 16),
          section: workbook.styles.add_style(bg_color: "DCEAF3", fg_color: "17324D", b: true),
          header: workbook.styles.add_style(bg_color: "17324D", fg_color: "FFFFFF", b: true, alignment: { wrap_text: true }),
          note: workbook.styles.add_style(fg_color: "52606D", italic: true, alignment: { wrap_text: true }),
          input: workbook.styles.add_style(bg_color: "FFF7D6"),
          hours: workbook.styles.add_style(num_fmt: 2, bg_color: "FFF7D6"),
          money: workbook.styles.add_style(num_fmt: 4, bg_color: "FFF7D6"),
          date: workbook.styles.add_style(num_fmt: 14)
        }
      end

      def add_start_sheet(workbook, styles)
        workbook.add_worksheet(name: START_SHEET) do |sheet|
          sheet.add_row([ "Cornerstone universal payroll workbook" ], style: styles[:title])
          sheet.merge_cells("A1:D1")
          sheet.add_row([ "Fill in the PAYROLL sheet for this pay period. Employees are matched strictly by Employee ID." ], style: styles[:note])
          sheet.merge_cells("A2:D2")
          sheet.add_row([])

          metadata = [
            [ "Schema version", SCHEMA_VERSION ],
            [ "Company ID", company.id ],
            [ "Company", company.name ],
            [ "Pay period start", start_date ],
            [ "Pay period end", end_date ],
            [ "Pay date", pay_date || "" ],
            [ "Pay schedule", pay_frequency ],
            [ "Overtime mode", effective_settings.overtime_mode ],
            [ "Tip treatment default", effective_settings.tips_default ]
          ]

          metadata.each_with_index do |(label, value), index|
            value_style = index.in?([ 3, 4, 5 ]) && value.is_a?(Date) ? styles[:date] : nil
            sheet.add_row([ label, value ], style: [ styles[:section], value_style ], escape_formulas: true)
          end

          sheet.add_row([])
          sheet.add_row([ "How to use this workbook" ], style: styles[:section])
          sheet.add_row([ "1", "Do not change Employee ID values. Cornerstone matches rows by Employee ID only, never by name." ])
          sheet.add_row([ "2", "Weekly/biweekly schedules using Payroll-calculated overtime: enter Week 1 Hours (and Week 2 Hours for biweekly)." ])
          sheet.add_row([ "3", "Semimonthly/monthly schedules (or source-reported overtime): enter Regular Hours and Overtime Hours." ])
          sheet.add_row([ "4", "Enter optional PTO Hours, Holiday Hours, Tips, Bonus, One-Time Items, and Loan Deductions in the matching columns." ])
          sheet.add_row([ "5", "Leave rows blank for employees with no hours or pay inputs this period. Negative hours and amounts are rejected." ])
          sheet.column_widths(30, 74, 16, 16)
        end
      end

      def add_payroll_sheet(workbook, styles)
        workbook.add_worksheet(name: PAYROLL_SHEET) do |sheet|
          sheet.add_row(COLUMNS, style: styles[:header])

          row_styles = [
            nil, nil,
            styles[:hours], styles[:hours], styles[:hours], styles[:hours],
            styles[:hours], styles[:hours],
            styles[:money], styles[:input],
            styles[:money], styles[:input], styles[:input], styles[:money],
            styles[:money], styles[:input]
          ]

          employees.each do |employee|
            sheet.add_row(
              [ employee.id, employee.full_name, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil ],
              style: row_styles,
              escape_formulas: true
            )
          end

          if employees.any?
            last_row = employees.length + 1
            add_list_validation(
              sheet,
              "J2:J#{last_row}",
              %w[YES NO],
              prompt: "Choose YES if tips were already paid outside payroll, NO if paid in check, or leave blank for default."
            )
            add_list_validation(
              sheet,
              "L2:L#{last_row}",
              ONE_TIME_ITEM_TYPES,
              prompt: "Choose the one-time item type so Cornerstone applies the correct tax treatment."
            )
          end

          sheet.auto_filter = "A1:P#{[ employees.length + 1, 2 ].max}"
          freeze_header!(sheet)
          sheet.column_widths(14, 28, 14, 14, 15, 16, 12, 14, 14, 24, 14, 24, 24, 20, 16, 32)
        end
      end

      def freeze_header!(sheet)
        sheet.sheet_view.pane do |pane|
          pane.top_left_cell = "A2"
          pane.state = :frozen
          pane.y_split = 1
          pane.active_pane = :bottom_left
        end
      end

      def add_list_validation(sheet, range, values, prompt:)
        sheet.add_data_validation(
          range,
          type: :list,
          formula1: %("#{values.join(',')}"),
          allowBlank: true,
          showErrorMessage: true,
          errorStyle: :stop,
          errorTitle: "Choose a listed value",
          error: "Use a listed value so Cornerstone can validate this payroll safely.",
          showInputMessage: true,
          promptTitle: "Cornerstone workbook",
          prompt: prompt
        )
      end

      def safe_csv_cell(value)
        text = value.to_s
        return "'#{text}" if text.present? && (FORMULA_PREFIXES.include?(text[0]) || text[0] == "\t" || text[0] == "\r")

        text
      end
    end
  end
end
