# frozen_string_literal: true

require "rails_helper"
require "caxlsx"

RSpec.describe PayrollImport::LoanTipExcelParser do
  def build_workbook
    tempfile = Tempfile.new([ "mosa-loans-tips", ".xlsx" ])
    package = Axlsx::Package.new

    package.workbook.add_worksheet(name: described_class::TIPS_BOH_SHEET) do |sheet|
      add_header_rows(sheet, title: "TIPS - BOH (KITCHEN)")
      sheet.add_row([ 1, nil, "Kitchen", "Employee", "Kitchen", 125.25 ])
      sheet.add_row([ 2, nil, "Dual", "Pool", "Kitchen", 10.00 ])
    end

    package.workbook.add_worksheet(name: described_class::TIPS_FOH_SHEET) do |sheet|
      add_header_rows(sheet, title: "TIPS - FOH (JOINT)")
      sheet.add_row([ 1, nil, "Joint", "Employee", "Joint", 225.75 ])
      sheet.add_row([ 2, nil, "Dual", "Pool", "Joint", 15.00 ])
    end

    package.workbook.add_worksheet(name: described_class::LOANS_SHEET) do |sheet|
      add_header_rows(sheet, title: "LOANS (DO NOT ENTER INSTALLMENT PAYMENTS)")
      sheet.add_row([ 1, nil, "Recurring", "Employee", "Joint", 50.00 ])
      sheet.add_row([ 2, nil, "Mixed", "Loan", "Kitchen", 20.00 ])
    end

    package.workbook.add_worksheet(name: described_class::INSTALLMENT_SHEET) do |sheet|
      add_header_rows(sheet, title: "INSTALLMENT LOANS")
      sheet.add_row([ 1, nil, "Installment", "Employee", "Joint", 300.00, 75.00, 50.00, 325.00 ])
      sheet.add_row([ 2, nil, "Mixed", "Loan", "Kitchen", 100.00, nil, 25.00, 75.00 ])
    end

    package.serialize(tempfile.path)
    tempfile
  end

  def add_header_rows(sheet, title:)
    sheet.add_row([ title ])
    sheet.add_row([ "PAY PERIOD ENDING", nil, nil, nil, nil, "5/16/2026" ])
    sheet.add_row([ "PAY DAY", nil, nil, nil, nil, "5/21/2026" ])
    sheet.add_row([ nil, "Nickname", "Last Name", "First Name", "Dept", "Amount", "New Loan", "Payment", "Estimated Ending" ])
  end

  it "preserves BOH and FOH tips while keeping the legacy total_tips field" do
    tempfile = build_workbook

    rows = described_class.parse(tempfile.path)
    employee = rows.find { |row| row[:last_name] == "Kitchen" && row[:first_name] == "Employee" }
    dual_pool = rows.find { |row| row[:last_name] == "Dual" && row[:first_name] == "Pool" }

    expect(employee).to include(
      total_tips: 125.25,
      tips_boh: 125.25,
      tips_foh: 0.0,
      tip_pool: "boh"
    )
    expect(dual_pool).to include(
      total_tips: 25.0,
      tips_boh: 10.0,
      tips_foh: 15.0,
      tip_pool: "mixed"
    )
  ensure
    tempfile&.unlink
  end

  it "preserves recurring and installment loan detail while keeping legacy loan_deduction" do
    tempfile = build_workbook

    rows = described_class.parse(tempfile.path)
    recurring = rows.find { |row| row[:last_name] == "Recurring" && row[:first_name] == "Employee" }
    installment = rows.find { |row| row[:last_name] == "Installment" && row[:first_name] == "Employee" }
    mixed = rows.find { |row| row[:last_name] == "Mixed" && row[:first_name] == "Loan" }

    expect(recurring).to include(
      recurring_loan_deduction: 50.0,
      installment_payment: 0.0,
      loan_deduction: 50.0
    )
    expect(installment).to include(
      recurring_loan_deduction: 0.0,
      installment_beginning_balance: 300.0,
      installment_new_amount: 75.0,
      installment_payment: 50.0,
      installment_estimated_ending_balance: 325.0,
      loan_deduction: 50.0
    )
    expect(mixed).to include(
      recurring_loan_deduction: 20.0,
      installment_beginning_balance: 100.0,
      installment_payment: 25.0,
      installment_estimated_ending_balance: 75.0,
      loan_deduction: 45.0
    )
  ensure
    tempfile&.unlink
  end
end
