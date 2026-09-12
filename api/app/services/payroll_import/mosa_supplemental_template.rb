# frozen_string_literal: true

require "caxlsx"

module PayrollImport
  class MosaSupplementalTemplate
    SCHEMA_VERSION = "cornerstone-mosa-supplemental/v2"
    LEGACY_SCHEMA_VERSION = "cornerstone-mosa-supplemental/v1"
    SUPPORTED_SCHEMA_VERSIONS = [ LEGACY_SCHEMA_VERSION, SCHEMA_VERSION ].freeze
    EMPLOYEE_CHANGES_SHEET = "EMPLOYEE CHANGES"
    OWNER_PERIOD_PAY_SHEET = "OWNER PERIOD PAY"
    ONE_TIME_COMPONENTS_SHEET = "ONE-TIME COMPONENTS"
    DEDUCTIONS_LOANS_SHEET = "DEDUCTIONS & LOANS"
    HOUR_CORRECTIONS_SHEET = "HOUR CORRECTIONS"
    ONE_TIME_ROWS_PER_EMPLOYEE = 2

    def initialize(pay_period)
      @pay_period = pay_period
      @company = pay_period.company
    end

    def generate
      package = Axlsx::Package.new
      workbook = package.workbook
      styles = build_styles(workbook)

      add_start_sheet(workbook, styles)
      add_employee_changes_sheet(workbook, styles)
      add_owner_period_pay_sheet(workbook, styles)
      add_one_time_components_sheet(workbook, styles)
      add_deductions_and_loans_sheet(workbook, styles)

      package.to_stream.read
    end

    def filename
      company_name = company.name.to_s.parameterize.presence || "client"
      "#{company_name}-payroll-changes-#{pay_period.end_date.iso8601}.xlsx"
    end

    private

    attr_reader :pay_period, :company

    def employees
      @employees ||= company.employees.active.includes(:department, :employee_loans, employee_payroll_fields: :payroll_field_definition)
        .order(:last_name, :first_name, :id)
    end

    def build_styles(workbook)
      {
        title: workbook.styles.add_style(bg_color: "17324D", fg_color: "FFFFFF", b: true, sz: 16),
        section: workbook.styles.add_style(bg_color: "DCEAF3", fg_color: "17324D", b: true),
        header: workbook.styles.add_style(bg_color: "17324D", fg_color: "FFFFFF", b: true, alignment: { wrap_text: true }),
        note: workbook.styles.add_style(fg_color: "52606D", italic: true, alignment: { wrap_text: true }),
        input: workbook.styles.add_style(bg_color: "FFF7D6"),
        money: workbook.styles.add_style(num_fmt: 4, bg_color: "FFF7D6"),
        date: workbook.styles.add_style(num_fmt: 14, bg_color: "FFF7D6")
      }
    end

    def add_start_sheet(workbook, styles)
      workbook.add_worksheet(name: "START HERE") do |sheet|
        sheet.add_row([ "Cornerstone payroll change-only workbook" ], style: styles[:title])
        sheet.merge_cells("A1:D1")
        sheet.add_row([ "Keep sending the Revel PDF for hours. Enter only facts that changed for this payroll in the yellow cells below." ], style: styles[:note])
        sheet.merge_cells("A2:D2")
        sheet.add_row([])
        metadata = [
          [ "Schema version", SCHEMA_VERSION ],
          [ "Company ID", company.id ],
          [ "Company", company.name ],
          [ "Pay period start", pay_period.start_date ],
          [ "Pay period end", pay_period.end_date ],
          [ "Pay date", pay_period.pay_date ],
          [ "Template revision", 1 ],
          [ "Prior revision replaced", "" ],
          [ "Submitter", "" ],
          [ "Submitted at", "" ],
          [ "Revel filename", "" ],
          [ "No supplemental changes? (YES/NO)", "NO" ],
          [ "Attestation", "I confirm these payroll changes are complete and accurate." ]
        ]
        metadata.each_with_index do |(label, value), index|
          value_style = index.in?([ 3, 4, 5 ]) ? styles[:date] : (index >= 7 ? styles[:input] : nil)
          sheet.add_row([ label, value ], style: [ styles[:section], value_style ], escape_formulas: true)
        end
        add_list_validation(sheet, "B15", %w[YES NO], prompt: "Choose YES only when there are no tips, loans, or one-time items to report.")
        sheet.add_row([])
        sheet.add_row([ "How to use this workbook" ], style: styles[:section])
        sheet.add_row([ "1", "Do not re-enter Revel hours. Upload the original Revel PDF with this workbook." ])
        sheet.add_row([ "2", "Use the stable Employee ID already filled in. Leave unchanged employees blank." ])
        sheet.add_row([ "3", "Enter Mo and Sara's pay separately on OWNER PERIOD PAY. Never enter a combined owner amount." ])
        sheet.add_row([ "4", "Use ONE-TIME COMPONENTS for period-only pay or deductions. Every row needs a type, source, and effective pay date." ])
        sheet.add_row([ "5", "For recurring setup, loan advances, retirement changes, or hour corrections, contact Cornerstone before payroll is imported." ])
        sheet.column_widths(34, 68, 16, 16)
      end
    end

    def add_employee_changes_sheet(workbook, styles)
      workbook.add_worksheet(name: EMPLOYEE_CHANGES_SHEET) do |sheet|
        headers = [
          "Employee ID", "Employee", "Department", "BOH tips", "FOH tips",
          "Tips already paid? (YES/NO)", "Source / reason", "Notes"
        ]
        sheet.add_row(headers, style: styles[:header])
        employees.each do |employee|
          sheet.add_row(
            [ employee.id, employee.full_name, employee.department&.name, nil, nil, nil, nil, nil ],
            style: [ nil, nil, nil, styles[:money], styles[:money], styles[:input], styles[:input], styles[:input] ],
            escape_formulas: true
          )
        end
        add_list_validation(sheet, "F2:F#{employees.length + 1}", %w[YES NO], prompt: "Choose whether these tips were already paid outside payroll.") if employees.any?
        sheet.auto_filter = "A1:H#{[ employees.length + 1, 2 ].max}"
        freeze_header!(sheet)
        sheet.column_widths(14, 28, 20, 14, 14, 22, 30, 36)
      end
    end

    def add_owner_period_pay_sheet(workbook, styles)
      workbook.add_worksheet(name: OWNER_PERIOD_PAY_SHEET) do |sheet|
        sheet.add_row(
          [ "Employee ID", "Employee", "Pay this employee", "Scope confirmation", "Effective pay date", "Source / reason", "Notes" ],
          style: styles[:header]
        )
        variable_salary_employees.each do |employee|
          sheet.add_row(
            [ employee.id, employee.full_name, nil, "THIS EMPLOYEE ONLY", pay_period.pay_date, nil, nil ],
            style: [ nil, nil, styles[:money], styles[:input], styles[:date], styles[:input], styles[:input] ],
            escape_formulas: true
          )
        end
        if variable_salary_employees.any?
          add_list_validation(
            sheet,
            "D2:D#{variable_salary_employees.length + 1}",
            [ "THIS EMPLOYEE ONLY" ],
            prompt: "Cornerstone requires one separate pay amount per person."
          )
        end
        if variable_salary_employees.empty?
          sheet.add_row([ "Reference only", "No variable-pay employees are active for this payroll." ], style: styles[:note])
        end
        sheet.add_row([ "Important", "Enter a separate amount for each person. A combined owner amount is rejected." ], style: styles[:note])
        freeze_header!(sheet)
        sheet.column_widths(14, 28, 20, 24, 18, 32, 38)
      end
    end

    def add_one_time_components_sheet(workbook, styles)
      workbook.add_worksheet(name: ONE_TIME_COMPONENTS_SHEET) do |sheet|
        sheet.add_row(
          [ "Employee ID", "Employee", "Type", "Label", "Amount", "Category", "Recipient / payee", "Effective pay date", "Source / reason", "Notes" ],
          style: styles[:header]
        )
        employees.each do |employee|
          ONE_TIME_ROWS_PER_EMPLOYEE.times do
            sheet.add_row(
              [ employee.id, employee.full_name, nil, nil, nil, nil, nil, pay_period.pay_date, nil, nil ],
              style: [ nil, nil, styles[:input], styles[:input], styles[:money], styles[:input], styles[:input], styles[:date], styles[:input], styles[:input] ],
              escape_formulas: true
            )
          end
        end
        component_last_row = employees.length * ONE_TIME_ROWS_PER_EMPLOYEE + 1
        if employees.any?
          add_list_validation(
            sheet,
            "C2:C#{component_last_row}",
            PayrollImport::LoanTipExcelParser::GENERATED_COMPONENT_TYPES.keys,
            prompt: "Choose the item type; Cornerstone derives the correct tax treatment."
          )
          add_list_validation(
            sheet,
            "F2:F#{component_last_row}",
            PayrollFieldDefinition::CATEGORIES - %w[loan retirement],
            prompt: "Choose a category. Manage loans and retirement directly in Cornerstone."
          )
        end
        sheet.add_row(
          [ "Allowed types", "BONUS · REIMBURSEMENT · OTHER TAXABLE EARNING · POST-TAX DEDUCTION" ],
          style: styles[:note]
        )
        sheet.add_row([ "More than two items", "Copy one of the employee's rows when that person has more than two one-time items." ], style: styles[:note])
        sheet.add_row([ "Recurring items", "Change recurring deductions, additions, loans, or retirement setup in Cornerstone—not in this sheet." ], style: styles[:note])
        freeze_header!(sheet)
        sheet.column_widths(14, 28, 26, 26, 14, 18, 24, 18, 32, 38)
      end
    end

    def add_deductions_and_loans_sheet(workbook, styles)
      workbook.add_worksheet(name: DEDUCTIONS_LOANS_SHEET) do |sheet|
        headers = [
          "Employee ID", "Employee", "Component ID", "Component", "Type", "Current amount",
          "Action (KEEP/CHANGE/STOP)", "Amount this payroll", "Effective date", "Stop date / rule",
          "Opening balance", "New advance", "Payment", "Ending balance", "Recipient / payee", "Source", "Notes"
        ]
        sheet.add_row(headers, style: styles[:header])

        component_rows.each do |row|
          sheet.add_row(
            row,
            style: [ nil, nil, nil, nil, nil, nil, styles[:input], styles[:money], styles[:date], styles[:input],
                    styles[:money], styles[:money], styles[:money], styles[:money], styles[:input], styles[:input], styles[:input] ],
            escape_formulas: true
          )
        end
        sheet.add_row([ "Reference only", "Recurring setup changes and new loan advances must be reviewed in Cornerstone before import." ], style: styles[:note])
        freeze_header!(sheet)
        sheet.column_widths(14, 28, 15, 26, 20, 16, 25, 18, 16, 24, 16, 14, 14, 16, 22, 28, 36)
      end
    end

    def component_rows
      rows = employees.flat_map do |employee|
        assignment_rows = employee.employee_payroll_fields.active.effective_on(pay_period.pay_date).map do |assignment|
          definition = assignment.payroll_field_definition
          loan = assignment.employee_loan
          component_type = if loan&.recurring_no_balance?
            "recurring deduction (no balance)"
          elsif loan&.balance_tracked?
            "installment loan"
          else
            definition.category
          end
          [
            employee.id, employee.full_name, definition.id, definition.name, component_type,
            assignment.effective_amount_for(0), "KEEP", nil, pay_period.pay_date, assignment.end_date,
            loan&.balance_tracked? ? loan.current_balance : nil, nil, nil, nil, nil, "Cornerstone recurring setup", nil
          ]
        end

        assigned_loan_ids = employee.employee_payroll_fields.filter_map(&:employee_loan_id)
        loan_rows = employee.employee_loans.active.reject { |loan| assigned_loan_ids.include?(loan.id) }.map do |loan|
          [
            employee.id, employee.full_name, "loan-#{loan.id}", loan.name,
            loan.recurring_no_balance? ? "recurring deduction (no balance)" : "installment loan", loan.payment_amount,
            "KEEP", nil, pay_period.pay_date, nil, loan.current_balance, nil, nil, nil, nil,
            "Cornerstone loan ledger", nil
          ]
        end
        legacy_rows = Array(employee.default_payroll_adjustments).each_with_index.filter_map do |adjustment, index|
          data = adjustment.to_h.with_indifferent_access
          next if data[:active] == false

          [
            employee.id, employee.full_name, "legacy-#{index + 1}", data[:label], data[:treatment], data[:amount],
            "KEEP", nil, pay_period.pay_date, nil, nil, nil, nil, nil, nil,
            "Cornerstone recurring setup", nil
          ]
        end

        assignment_rows + loan_rows + legacy_rows
      end

      return rows if rows.any?

      [ [ nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil ] ]
    end

    def variable_salary_employees
      @variable_salary_employees ||= employees.select(&:variable_salary?)
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
        error: "Use the dropdown so Cornerstone can validate this payroll safely.",
        showInputMessage: true,
        promptTitle: "Cornerstone payroll",
        prompt: prompt
      )
    end
  end
end
