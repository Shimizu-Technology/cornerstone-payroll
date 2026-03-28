# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Generates an Employee Installment Loan Report PDF showing loan balances
# and transaction history — modeled after the QuickBooks version.
class InstallmentLoanReportPdfGenerator
  include PdfFooter

  HEADER_BG   = "2B4090"
  SECTION_BG  = "F0F4FF"
  BORDER_GRAY = "CCCCCC"
  TEXT_DARK   = "1A1A2E"
  TEXT_MUTED  = "666666"

  attr_reader :company, :as_of_date

  # @param company [Company]
  # @param as_of_date [Date] show loan state as of this date (defaults to today)
  def initialize(company, as_of_date: nil)
    @company = company
    @as_of_date = as_of_date || Date.current
  end

  def generate
    loans = company.employee_loans
      .includes(:employee, loan_transactions: :pay_period)
      .order("employees.last_name ASC, employees.first_name ASC, employee_loans.name ASC")

    pdf = Prawn::Document.new(page_size: "LETTER", page_layout: :portrait, margin: [36, 36, 50, 36])
    render_document(pdf, loans.to_a)
  end

  def filename
    "employee_installment_loans_#{as_of_date}.pdf"
  end

  private

  def render_document(pdf, loans)
    render_header(pdf)

    if loans.empty?
      pdf.text "No employee loans found.", style: :italic, color: TEXT_MUTED
      return
    end

    loans.group_by(&:employee).each do |employee, emp_loans|
      render_employee_loans(pdf, employee, emp_loans)
    end

    render_with_footer(pdf,
      "#{company.name} \u2014 Employee Installment Loan Report \u2014 CONFIDENTIAL"
    )
  end

  def render_header(pdf)
    pdf.font_size(16) { pdf.text company.name, style: :bold, color: HEADER_BG }
    pdf.font_size(11) { pdf.text "Employee Installment Loan Report", color: TEXT_DARK }
    pdf.font_size(9) { pdf.text "As of #{as_of_date.strftime('%b %d, %Y')}", color: TEXT_MUTED }
    pdf.move_down 14
  end

  def render_employee_loans(pdf, employee, loans)
    pdf.start_new_page if pdf.cursor < 120

    pdf.font_size(10) do
      pdf.text employee.full_name, style: :bold, color: HEADER_BG
    end
    pdf.move_down 4

    loans.each do |loan|
      render_loan_detail(pdf, loan)
    end

    pdf.move_down 10
  end

  def render_loan_detail(pdf, loan)
    pdf.start_new_page if pdf.cursor < 80

    status_text = loan.status.capitalize
    status_text += " (#{loan.paid_off_date.strftime('%m/%d/%Y')})" if loan.paid_off?

    pdf.font_size(9) do
      pdf.text "#{loan.name} — Original: #{fmt(loan.original_amount)} | Current Balance: #{fmt(loan.current_balance)} | Status: #{status_text}",
        style: :bold
    end
    pdf.move_down 2

    transactions = loan.loan_transactions.chronological.to_a
    if transactions.empty?
      pdf.font_size(8) { pdf.text "No transactions recorded.", style: :italic, color: TEXT_MUTED }
      pdf.move_down 6
      return
    end

    header = ["Date", "Beginning Balance", "Additions", "Payments", "Ending Balance"].map do |label|
      { content: label, background_color: HEADER_BG, text_color: "FFFFFF",
        font_style: :bold, align: label == "Date" ? :left : :right }
    end

    rows = transactions.map do |txn|
      additions = txn.transaction_type == "addition" ? fmt(txn.amount) : "—"
      payments = txn.transaction_type == "payment" ? "(#{fmt(txn.amount)})" : "—"

      [
        { content: txn.transaction_date.strftime("%m/%d/%Y") },
        { content: fmt(txn.balance_before), align: :right },
        { content: additions, align: :right },
        { content: payments, align: :right },
        { content: fmt(txn.balance_after), align: :right }
      ]
    end

    pdf.table([header] + rows,
      width: pdf.bounds.width * 0.85,
      cell_style: { size: 7, padding: [3, 5], border_color: BORDER_GRAY }
    )
    pdf.move_down 6
  end

  def fmt(value)
    "$#{format('%.2f', value.to_f)}"
  end
end
