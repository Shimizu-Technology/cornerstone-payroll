# frozen_string_literal: true

require "caxlsx"

module PayrollImport
  class MosaSupplementalTemplate
    SCHEMA_VERSION = "cornerstone-mosa-supplemental/v1"
    EMPLOYEE_CHANGES_SHEET = "EMPLOYEE CHANGES"
    DEDUCTIONS_LOANS_SHEET = "DEDUCTIONS & LOANS"
    HOUR_CORRECTIONS_SHEET = "HOUR CORRECTIONS"

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
          sheet.add_row([ label, value ], style: [ styles[:section], value_style ])
        end
        sheet.add_row([])
        sheet.add_row([ "How to use this workbook" ], style: styles[:section])
        sheet.add_row([ "1", "Do not re-enter Revel hours. Upload the original Revel PDF with this workbook." ])
        sheet.add_row([ "2", "Use the stable Employee ID already filled in. Leave unchanged employees blank." ])
        sheet.add_row([ "3", "Tips and deductions are proposals until Cornerstone reviews and applies them." ])
        sheet.add_row([ "4", "For recurring setup, loan advances, or hour corrections, contact Cornerstone before payroll is imported." ])
        sheet.column_widths(34, 68, 16, 16)
      end
    end

    def add_employee_changes_sheet(workbook, styles)
      workbook.add_worksheet(name: EMPLOYEE_CHANGES_SHEET) do |sheet|
        headers = [
          "Employee ID", "Employee", "Department", "BOH tips", "FOH tips",
          "Tips already paid? (YES/NO)", "One-time bonus", "One-payroll deduction",
          "Effective date", "Recipient / payee", "Source / reason", "Notes"
        ]
        sheet.add_row(headers, style: styles[:header])
        employees.each do |employee|
          sheet.add_row(
            [ employee.id, employee.full_name, employee.department&.name, nil, nil, nil, nil, nil, nil, nil, nil, nil ],
            style: [ nil, nil, nil, styles[:money], styles[:money], styles[:input], styles[:money], styles[:money], styles[:date], styles[:input], styles[:input], styles[:input] ]
          )
        end
        sheet.auto_filter = "A1:L#{[ employees.length + 1, 2 ].max}"
        freeze_header!(sheet)
        sheet.column_widths(14, 28, 20, 14, 14, 22, 16, 20, 16, 22, 30, 36)
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
                    styles[:money], styles[:money], styles[:money], styles[:money], styles[:input], styles[:input], styles[:input] ]
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

    def freeze_header!(sheet)
      sheet.sheet_view.pane do |pane|
        pane.top_left_cell = "A2"
        pane.state = :frozen
        pane.y_split = 1
        pane.active_pane = :bottom_left
      end
    end
  end
end
