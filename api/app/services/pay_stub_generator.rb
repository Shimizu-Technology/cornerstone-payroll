# frozen_string_literal: true

require "prawn"
require "prawn/table"

# Generates PDF pay stubs for employees
#
# Usage:
#   generator = PayStubGenerator.new(payroll_item)
#   pdf_data = generator.generate
#   # pdf_data is raw PDF binary
#
class PayStubGenerator
  attr_reader :payroll_item, :employee, :pay_period, :company

  def initialize(payroll_item)
    @payroll_item = payroll_item
    @employee = payroll_item.employee
    @pay_period = payroll_item.pay_period
    @company = pay_period.company
  end

  def generate
    Prawn::Document.new(page_size: "LETTER", margin: 40) do |pdf|
      # Header
      render_header(pdf)
      
      # Employee Info
      render_employee_info(pdf)
      
      # Pay Period Info
      render_pay_period_info(pdf)
      
      # Earnings Section
      render_earnings(pdf)
      
      # Deductions Section
      render_deductions(pdf)
      
      # Net Pay
      render_net_pay(pdf)
      
      # YTD Summary
      render_ytd_summary(pdf)
      
      # Footer
      render_footer(pdf)
    end.render
  end

  def filename
    "paystub_#{employee.id}_#{pay_period.pay_date.strftime('%Y%m%d')}.pdf"
  end

  private

  def render_header(pdf)
    pdf.font_size(18) do
      pdf.text company.name, style: :bold
    end
    
    if company.address_line1.present?
      pdf.font_size(10) do
        pdf.text company.address_line1
        pdf.text company.address_line2 if company.address_line2.present?
        pdf.text "#{company.city}, #{company.state} #{company.zip}"
        pdf.text company.phone if company.phone.present?
      end
    end
    
    pdf.move_down 10
    pdf.stroke_horizontal_rule
    pdf.move_down 15
    
    pdf.font_size(14) do
      pdf.text "EARNINGS STATEMENT", style: :bold, align: :center
    end
    pdf.move_down 15
  end

  def render_employee_info(pdf)
    pdf.font_size(10) do
      data = [
        ["Employee:", employee.full_name],
        ["Employee ID:", employee.id.to_s],
        ["SSN:", "XXX-XX-#{employee.ssn_last_four || '****'}"],
        ["Department:", employee.department&.name || "N/A"]
      ]
      
      pdf.table(data, cell_style: { borders: [], padding: [2, 10, 2, 0] }) do
        column(0).font_style = :bold
        column(0).width = 100
      end
    end
    pdf.move_down 15
  end

  def render_pay_period_info(pdf)
    pdf.font_size(10) do
      data = [
        ["Pay Period:", "#{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}"],
        ["Pay Date:", format_date(pay_period.pay_date)],
        ["Check #:", payroll_item.check_number || "Direct Deposit"]
      ]
      
      pdf.table(data, cell_style: { borders: [], padding: [2, 10, 2, 0] }) do
        column(0).font_style = :bold
        column(0).width = 100
      end
    end
    pdf.move_down 20
  end

  def render_earnings(pdf)
    pdf.font_size(11) do
      pdf.text "EARNINGS", style: :bold
    end
    pdf.move_down 5
    
    earnings_data = [["Description", "Hours", "Rate", "Current", "YTD"]]
    
    if payroll_item.hourly?
      # Regular pay
      if payroll_item.hours_worked.to_f > 0
        earnings_data << [
          "Regular",
          format_hours(payroll_item.hours_worked),
          format_currency(payroll_item.pay_rate),
          format_currency(payroll_item.hours_worked.to_f * payroll_item.pay_rate),
          "—"
        ]
      end
      
      # Overtime
      if payroll_item.overtime_hours.to_f > 0
        earnings_data << [
          "Overtime (1.5x)",
          format_hours(payroll_item.overtime_hours),
          format_currency(payroll_item.pay_rate * 1.5),
          format_currency(payroll_item.overtime_hours.to_f * payroll_item.pay_rate * 1.5),
          "—"
        ]
      end
      
      # Holiday
      if payroll_item.holiday_hours.to_f > 0
        earnings_data << [
          "Holiday",
          format_hours(payroll_item.holiday_hours),
          format_currency(payroll_item.pay_rate),
          format_currency(payroll_item.holiday_hours.to_f * payroll_item.pay_rate),
          "—"
        ]
      end
      
      # PTO
      if payroll_item.pto_hours.to_f > 0
        earnings_data << [
          "PTO",
          format_hours(payroll_item.pto_hours),
          format_currency(payroll_item.pay_rate),
          format_currency(payroll_item.pto_hours.to_f * payroll_item.pay_rate),
          "—"
        ]
      end
    else
      # Salary
      earnings_data << [
        "Salary",
        "—",
        "#{format_currency(payroll_item.pay_rate)}/yr",
        format_currency(payroll_item.gross_pay - payroll_item.bonus.to_f - payroll_item.reported_tips.to_f),
        "—"
      ]
    end
    
    # Bonus
    if payroll_item.bonus.to_f > 0
      earnings_data << ["Bonus", "—", "—", format_currency(payroll_item.bonus), "—"]
    end
    
    # Tips
    if payroll_item.reported_tips.to_f > 0
      earnings_data << ["Reported Tips", "—", "—", format_currency(payroll_item.reported_tips), "—"]
    end
    
    # Gross total
    earnings_data << [
      { content: "GROSS PAY", font_style: :bold },
      "",
      "",
      { content: format_currency(payroll_item.gross_pay), font_style: :bold },
      { content: format_currency(payroll_item.ytd_gross), font_style: :bold }
    ]
    
    pdf.font_size(9) do
      pdf.table(earnings_data, header: true, width: pdf.bounds.width) do
        row(0).font_style = :bold
        row(0).background_color = "EEEEEE"
        cells.padding = [5, 8]
        columns(1..4).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end
    
    pdf.move_down 20
  end

  def render_deductions(pdf)
    pdf.font_size(11) do
      pdf.text "DEDUCTIONS", style: :bold
    end
    pdf.move_down 5
    
    deductions_data = [["Description", "Current", "YTD"]]
    
    # Federal/Guam Withholding
    deductions_data << [
      "Federal/Guam Income Tax",
      format_currency(payroll_item.withholding_tax),
      format_currency(payroll_item.ytd_withholding_tax)
    ]
    
    # Social Security
    deductions_data << [
      "Social Security (6.2%)",
      format_currency(payroll_item.social_security_tax),
      format_currency(payroll_item.ytd_social_security_tax)
    ]
    
    # Medicare
    deductions_data << [
      "Medicare (1.45%)",
      format_currency(payroll_item.medicare_tax),
      format_currency(payroll_item.ytd_medicare_tax)
    ]
    
    # Additional withholding
    if payroll_item.additional_withholding.to_f > 0
      deductions_data << [
        "Additional Withholding",
        format_currency(payroll_item.additional_withholding),
        "—"
      ]
    end
    
    # Retirement
    if payroll_item.retirement_payment.to_f > 0
      deductions_data << [
        "401(k) Retirement",
        format_currency(payroll_item.retirement_payment),
        format_currency(payroll_item.ytd_retirement)
      ]
    end
    
    # Roth Retirement
    if payroll_item.roth_retirement_payment.to_f > 0
      deductions_data << [
        "Roth 401(k)",
        format_currency(payroll_item.roth_retirement_payment),
        format_currency(payroll_item.ytd_roth_retirement)
      ]
    end
    
    # Insurance
    if payroll_item.insurance_payment.to_f > 0
      deductions_data << [
        "Health Insurance",
        format_currency(payroll_item.insurance_payment),
        "—"
      ]
    end
    
    # Loan
    if payroll_item.loan_payment.to_f > 0
      deductions_data << [
        "Loan Repayment",
        format_currency(payroll_item.loan_payment),
        "—"
      ]
    end
    
    # Total deductions
    deductions_data << [
      { content: "TOTAL DEDUCTIONS", font_style: :bold },
      { content: format_currency(payroll_item.total_deductions), font_style: :bold },
      "—"
    ]
    
    pdf.font_size(9) do
      pdf.table(deductions_data, header: true, width: pdf.bounds.width) do
        row(0).font_style = :bold
        row(0).background_color = "EEEEEE"
        cells.padding = [5, 8]
        columns(1..2).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end
    
    pdf.move_down 20
  end

  def render_net_pay(pdf)
    pdf.bounding_box([pdf.bounds.width - 200, pdf.cursor], width: 200) do
      data = [
        [
          { content: "NET PAY", font_style: :bold },
          { content: format_currency(payroll_item.net_pay), font_style: :bold }
        ]
      ]
      
      pdf.font_size(12) do
        pdf.table(data, width: 200) do
          cells.padding = [10, 15]
          cells.background_color = "E8F5E9"
          column(1).align = :right
        end
      end
    end
    
    pdf.move_down 30
  end

  def render_ytd_summary(pdf)
    pdf.font_size(11) do
      pdf.text "YEAR-TO-DATE SUMMARY", style: :bold
    end
    pdf.move_down 5
    
    ytd_data = [
      ["Gross Earnings", format_currency(payroll_item.ytd_gross)],
      ["Federal/Guam Tax", format_currency(payroll_item.ytd_withholding_tax)],
      ["Social Security", format_currency(payroll_item.ytd_social_security_tax)],
      ["Medicare", format_currency(payroll_item.ytd_medicare_tax)],
      ["Net Pay", format_currency(payroll_item.ytd_net)]
    ]
    
    pdf.font_size(9) do
      pdf.table(ytd_data, width: 250) do
        cells.padding = [4, 8]
        cells.borders = []
        column(0).font_style = :bold
        column(1).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end
  end

  def render_footer(pdf)
    pdf.move_down 30
    pdf.stroke_horizontal_rule
    pdf.move_down 10
    
    pdf.font_size(8) do
      pdf.text "This is your official earnings statement. Please retain for your records.", align: :center, color: "666666"
      pdf.text "Generated on #{Time.current.strftime('%B %d, %Y at %I:%M %p')}", align: :center, color: "999999"
    end
  end

  def format_currency(amount)
    return "$0.00" if amount.nil?
    "$#{sprintf('%.2f', amount.to_f).reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
  end

  def format_hours(hours)
    return "0.00" if hours.nil?
    sprintf("%.2f", hours.to_f)
  end

  def format_date(date)
    date.strftime("%m/%d/%Y")
  end
end
