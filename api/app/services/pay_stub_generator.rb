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
  include PdfFooter

  GUAM_TIME_ZONE = "Pacific/Guam"

  attr_reader :payroll_item, :employee, :pay_period, :company

  def initialize(payroll_item)
    @payroll_item = payroll_item
    @employee = payroll_item.employee
    @pay_period = payroll_item.pay_period
    @company = pay_period.company
  end

  def generate
    pdf = Prawn::Document.new(page_size: "LETTER", margin: [ 32, 32, 64, 32 ])

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

    render_with_footer(
      pdf,
      "This is your official earnings statement. Please retain for your records.\nGenerated on #{guam_generated_timestamp}",
      font_size: 7,
      height: 30
    )
  end

  def filename
    "paystub_#{employee.id}_#{pay_period.pay_date.strftime('%Y%m%d')}.pdf"
  end

  private

  def render_header(pdf)
    pdf.font_size(16) do
      pdf.text company.name, style: :bold
    end

    if company.address_line1.present?
      pdf.font_size(9) do
        pdf.text company.address_line1
        pdf.text company.address_line2 if company.address_line2.present?
        pdf.text "#{company.city}, #{company.state} #{company.zip}"
        pdf.text company.phone if company.phone.present?
      end
    end

    pdf.move_down 6
    pdf.stroke_horizontal_rule
    pdf.move_down 10

    pdf.font_size(13) do
      pdf.text "EARNINGS STATEMENT", style: :bold, align: :center
    end
    pdf.move_down 10
  end

  def render_employee_info(pdf)
    pdf.font_size(9) do
      data = [
        [ "Employee:", employee.full_name ],
        [ "Employee ID:", employee.id.to_s ],
        [ "SSN:", "XXX-XX-#{employee.ssn_last_four || '****'}" ],
        [ "Department:", employee.department&.name || "N/A" ]
      ]

      pdf.table(data, cell_style: { borders: [], padding: [ 2, 10, 2, 0 ] }) do
        column(0).font_style = :bold
        column(0).width = 100
      end
    end
    pdf.move_down 10
  end

  def render_pay_period_info(pdf)
    pdf.font_size(9) do
      data = [
        [ "Pay Period:", "#{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}" ],
        [ "Pay Date:", format_date(payroll_item.check_date || pay_period.pay_date) ],
        [ "Check #:", payroll_item.check_number || "Direct Deposit" ]
      ]

      pdf.table(data, cell_style: { borders: [], padding: [ 2, 10, 2, 0 ] }) do
        column(0).font_style = :bold
        column(0).width = 100
      end
    end
    pdf.move_down 12
  end

  def render_earnings(pdf)
    pdf.font_size(10) do
      pdf.text "EARNINGS", style: :bold
    end
    pdf.move_down 3

    earnings_data = [ [ "Description", "Hours", "Rate", "Current", "YTD" ] ]

    item_earnings = payroll_item.payroll_item_earnings.to_a

    if item_earnings.any?
      item_earnings.each do |earning|
        earnings_data << [
          earning.label.presence || earning.category.to_s.titleize,
          earning.hours.present? ? format_hours(earning.hours) : "—",
          earning.rate.present? ? format_currency(earning.rate) : "—",
          format_currency(earning.amount),
          "—"
        ]
      end
    elsif payroll_item.hourly?
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
      # Salary — subtract bonus, tips, and taxable adjustment earnings so they appear as separate lines
      ce_total = Array(payroll_item.custom_earnings).sum { |ce| ce["amount"].to_f } + payroll_item.taxable_payroll_adjustments_total
      earnings_data << [
        "Salary",
        "—",
        "#{format_currency(payroll_item.pay_rate)}/yr",
        format_currency(payroll_item.gross_pay - payroll_item.bonus.to_f - payroll_item.reported_tips.to_f - ce_total),
        "—"
      ]
    end

    existing_earning_categories = item_earnings.map { |earning| earning.category.to_s }
    existing_other_labels = item_earnings
      .select { |earning| earning.category.to_s == "other" }
      .map { |earning| earning.label.to_s.strip.downcase }

    # Bonus
    if payroll_item.bonus.to_f > 0 && !existing_earning_categories.include?("bonus")
      earnings_data << [ "Bonus", "—", "—", format_currency(payroll_item.bonus), "—" ]
    end

    # Tips
    if payroll_item.reported_tips.to_f > 0 && !existing_earning_categories.include?("tips")
      earnings_data << [ "Reported Tips", "—", "—", format_currency(payroll_item.reported_tips), "—" ]
    end

    # Custom earnings (e.g. Chief Stipend, Asst Chief Stipend)
    Array(payroll_item.custom_earnings).each do |ce|
      label = ce["label"].presence || "Other Earning"
      amt = ce["amount"].to_f
      if amt > 0 && !existing_other_labels.include?(label.to_s.strip.downcase)
        earnings_data << [ label, "—", "—", format_currency(amt), "—" ]
      end
    end

    # Gross total
    earnings_data << [
      { content: "GROSS PAY", font_style: :bold },
      "",
      "",
      { content: format_currency(payroll_item.gross_pay), font_style: :bold },
      { content: format_currency(payroll_item.ytd_gross), font_style: :bold }
    ]

    pdf.font_size(8) do
      pdf.table(earnings_data, header: true, width: pdf.bounds.width) do
        row(0).font_style = :bold
        row(0).background_color = "EEEEEE"
        cells.padding = [ 3, 6 ]
        columns(1..4).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end

    pdf.move_down 12
  end

  def render_deductions(pdf)
    pdf.font_size(10) do
      pdf.text "DEDUCTIONS", style: :bold
    end
    pdf.move_down 3

    deductions_data = [ [ "Description", "Current", "YTD" ] ]

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

    if payroll_item.withholding_tax_override.present?
      deductions_data << [
        "  (Final FIT Override Applied)",
        "",
        ""
      ]
    elsif payroll_item.withholding_tax_adjustment.to_f.nonzero?
      deductions_data << [
        format("  (FIT Adjustment %s%s)", payroll_item.withholding_tax_adjustment.to_f.positive? ? "+" : "", format_currency(payroll_item.withholding_tax_adjustment).delete("$")),
        "",
        ""
      ]
    end

    if payroll_item.additional_withholding.to_f > 0
      ytd_addl = employee_ytd_additional_withholding
      deductions_data << [
        "Additional Withholding (W-4 4c)",
        format_currency(payroll_item.additional_withholding),
        format_currency(ytd_addl)
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

    if payroll_item.tips_paid_out.to_f > 0
      deductions_data << [
        "Tips Paid Out",
        format_currency(payroll_item.tips_paid_out),
        format_currency(employee_ytd_tips_paid_out)
      ]
    end

    Array(payroll_item.custom_deductions).each do |deduction|
      amount = deduction["amount"].to_f
      next unless amount.positive?

      label = deduction["label"].presence || "Other Deduction"
      deductions_data << [
        label,
        format_currency(amount),
        format_currency(employee_ytd_custom_deductions_by_label[label.to_s.strip.downcase].to_f)
      ]
    end

    # Total deductions
    deductions_data << [
      { content: "TOTAL DEDUCTIONS", font_style: :bold },
      { content: format_currency(payroll_item.total_deductions), font_style: :bold },
      "—"
    ]

    pdf.font_size(8) do
      pdf.table(deductions_data, header: true, width: pdf.bounds.width) do
        row(0).font_style = :bold
        row(0).background_color = "EEEEEE"
        cells.padding = [ 3, 6 ]
        columns(1..2).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end

    pdf.move_down 12
  end

  def render_net_pay(pdf)
    pdf.bounding_box([ pdf.bounds.width - 200, pdf.cursor ], width: 200) do
      data = [
        [
          { content: "NET PAY", font_style: :bold },
          { content: format_currency(payroll_item.net_pay), font_style: :bold }
        ]
      ]

      pdf.font_size(11) do
        pdf.table(data, width: 200) do
          cells.padding = [ 7, 12 ]
          cells.background_color = "E8F5E9"
          column(1).align = :right
        end
      end
    end

    pdf.move_down 14
  end

  def render_ytd_summary(pdf)
    pdf.font_size(10) do
      pdf.text "YEAR-TO-DATE SUMMARY", style: :bold
    end
    pdf.move_down 3

    ytd_data = [
      [ "Gross Earnings", format_currency(payroll_item.ytd_gross) ],
      [ "Federal/Guam Tax", format_currency(payroll_item.ytd_withholding_tax) ],
      [ "Social Security", format_currency(payroll_item.ytd_social_security_tax) ],
      [ "Medicare", format_currency(payroll_item.ytd_medicare_tax) ],
      [ "Net Pay", format_currency(payroll_item.ytd_net) ]
    ]

    pdf.font_size(8) do
      pdf.table(ytd_data, width: 250) do
        cells.padding = [ 3, 6 ]
        cells.borders = []
        column(0).font_style = :bold
        column(1).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end
  end

  def guam_generated_timestamp
    Time.current.in_time_zone(GUAM_TIME_ZONE).strftime("%B %d, %Y at %I:%M %p ChST")
  end

  def employee_ytd_additional_withholding
    year = payroll_item.pay_period.pay_date&.year || Date.current.year
    payroll_item.employee.ytd_totals_through(
      year: year,
      pay_date: payroll_item.pay_period.pay_date,
      pay_period_id: payroll_item.pay_period_id
    )[:additional_withholding].to_f
  end

  def employee_ytd_tips_paid_out
    year = payroll_item.pay_period.pay_date&.year || Date.current.year
    payroll_item.employee.ytd_totals_through(
      year: year,
      pay_date: payroll_item.pay_period.pay_date,
      pay_period_id: payroll_item.pay_period_id
    )[:tips_paid_out].to_f
  end

  def employee_ytd_custom_deductions_by_label
    @employee_ytd_custom_deductions_by_label ||= begin
      labels = Array(payroll_item.custom_deductions)
        .filter_map { |deduction| deduction["label"].to_s.strip.downcase.presence }
        .uniq
      if labels.empty?
        {}
      else
        custom_deduction_items.each_with_object(Hash.new(0.0)) do |item, totals|
          Array(item.custom_deductions).each do |deduction|
            label = deduction["label"].to_s.strip.downcase
            next unless labels.include?(label)

            totals[label] += deduction["amount"].to_f
          end
        end
      end
    end
  end

  def custom_deduction_items
    year = payroll_item.pay_period.pay_date&.year || Date.current.year

    payroll_item.employee.payroll_items
      .joins(:pay_period)
      .select(:id, :custom_deductions)
      .not_voided
      .where(pay_periods: {
        company_id: payroll_item.company_id,
        pay_date: Date.new(year, 1, 1)..payroll_item.pay_period.pay_date
      })
      .where(
        "pay_periods.pay_date < :pay_date OR (pay_periods.pay_date = :pay_date AND pay_periods.id <= :pay_period_id)",
        pay_date: payroll_item.pay_period.pay_date,
        pay_period_id: payroll_item.pay_period.id
      )
      .to_a
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
