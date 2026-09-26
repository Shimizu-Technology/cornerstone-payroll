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

    # Non-taxable additions that increase net pay but not gross wages
    render_non_taxable_additions(pdf)

    # Employer-paid obligations that do not reduce net pay
    render_employer_contributions(pdf)

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
        payroll_item.effective_payment_delivery_method == "direct_deposit" ?
          [ "Payment:", "Direct deposit (stub only; transfer not confirmed)" ] :
          [ "Check #:", payroll_item.check_number.presence || "No check issued" ]
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

    # Non-taxable earnings are printed in their own section because they increase
    # net pay but are intentionally excluded from gross pay.
    item_earnings = payroll_item.payroll_item_earnings.reject { |earning| earning.category.to_s == "non_taxable" }

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

    payroll_item.active_payroll_adjustments.each do |adjustment|
      next unless adjustment["treatment"] == "taxable_addition"

      label = adjustment["label"].presence || "Taxable Adjustment"
      amount = adjustment["amount"].to_f
      if amount > 0 && !existing_other_labels.include?(label.to_s.strip.downcase)
        earnings_data << [ label, "—", "—", format_currency(amount), "—" ]
      end
    end

    payroll_field_entries_for("taxable_addition").each do |entry|
      earnings_data << [ entry.label, "—", "—", format_currency(entry.amount), format_currency(ytd_payroll_field_amount(entry)) ] if entry.amount.to_f.positive?
    end

    # Gross total
    earnings_data << [
      { content: "GROSS PAY", font_style: :bold },
      "",
      "",
      { content: format_currency(payroll_item.gross_pay), font_style: :bold },
      { content: format_currency(pay_ytd_total), font_style: :bold }
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

    ytd_addl = employee_ytd_additional_withholding
    if payroll_item.additional_withholding.to_d.nonzero? || ytd_addl.nonzero?
      deductions_data << [
        "Additional Withholding (W-4 4c)",
        format_currency(payroll_item.additional_withholding),
        format_currency(ytd_addl)
      ]
    end

    statement_ytd_breakdown.deductions.each do |row|
      deductions_data << [ pay_stub_deduction_label(row), format_currency(row.current), format_currency(row.ytd) ]
    end

    # Total deductions
    deductions_data << [
      { content: "TOTAL DEDUCTIONS", font_style: :bold },
      { content: format_currency(current_total_deductions), font_style: :bold },
      { content: format_currency(ytd_total_deductions), font_style: :bold }
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

  def render_non_taxable_additions(pdf)
    additions = statement_ytd_breakdown.other_pay.map do |row|
      [ row.label, format_currency(row.current), format_currency(row.ytd) ]
    end

    return if additions.empty?

    pdf.font_size(10) do
      pdf.text "NON-TAXABLE ADDITIONS", style: :bold
    end
    pdf.move_down 3

    additions_data = [ [ "Description", "Current", "YTD" ], *additions ]
    pdf.font_size(8) do
      pdf.table(additions_data, header: true, width: pdf.bounds.width) do
        row(0).font_style = :bold
        row(0).background_color = "EEEEEE"
        cells.padding = [ 3, 6 ]
        columns(1..2).align = :right
      end
    end

    pdf.move_down 12
  end

  def render_employer_contributions(pdf)
    entries = statement_ytd_breakdown.employer_contributions
    return if entries.empty?

    pdf.font_size(10) do
      pdf.text "EMPLOYER CONTRIBUTIONS", style: :bold
    end
    pdf.move_down 3

    rows = [ [ "Description", "Current", "YTD" ] ] + entries.map do |entry|
      [ entry.label, format_currency(entry.current), format_currency(entry.ytd) ]
    end
    rows << [
      { content: "TOTAL EMPLOYER CONTRIBUTIONS", font_style: :bold },
      { content: format_currency(entries.sum(0.to_d) { |entry| entry.current.to_d }), font_style: :bold },
      { content: format_currency(entries.sum(0.to_d) { |entry| entry.ytd.to_d }), font_style: :bold }
    ]

    pdf.font_size(8) do
      pdf.table(rows, header: true, width: pdf.bounds.width) do
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
      [ "Gross Earnings", format_currency(pay_ytd_total) ],
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

  def pay_ytd_total
    @pay_ytd_total ||= begin
      totals = employee.ytd_totals_before(
        year: pay_period.pay_date.year,
        pay_date: pay_period.pay_date,
        pay_period_id: pay_period.id
      )
      gross = totals.fetch(:gross_pay).to_d + payroll_item.gross_pay.to_d
      PayrollEarningsYtdBreakdown.new(payroll_item).pay_ytd_total(gross)
    end
  end

  def payroll_field_entries_for(*treatments)
    payroll_item.payroll_item_field_entries.select { |entry| entry.active? && treatments.include?(entry.tax_treatment) }
  end

  def ytd_payroll_field_amount(entry)
    ytd_payroll_field_totals.fetch([ entry.label, entry.tax_treatment, entry.category ], 0.to_d)
  end

  def ytd_total_deductions
    payroll_item.ytd_withholding_tax.to_d + payroll_item.ytd_social_security_tax.to_d + payroll_item.ytd_medicare_tax.to_d +
      employee_ytd_additional_withholding + statement_ytd_breakdown.deductions.sum(0.to_d) { |row| row.ytd.to_d }
  end

  def current_total_deductions
    payroll_item.withholding_tax.to_d + payroll_item.social_security_tax.to_d + payroll_item.medicare_tax.to_d +
      payroll_item.additional_withholding.to_d + statement_ytd_breakdown.deductions.sum(0.to_d) { |row| row.current.to_d }
  end

  def statement_ytd_breakdown
    @statement_ytd_breakdown ||= PayrollStatementYtdBreakdown.new(payroll_item)
  end

  def pay_stub_deduction_label(row)
    case row.semantic
    when PayrollReportingGroups::GROUP_401K_PRE_TAX.to_sym
      "401(k) Retirement"
    when :loan
      row.label == "Loan" ? "Loan Repayment" : row.label
    else
      row.label
    end
  end

  def ytd_source_items
    @ytd_source_items ||= begin
      pay_date = pay_period.pay_date
      prior_periods = PayPeriod.reportable_for_company(company).where(
        pay_date: Date.new(pay_date.year, 1, 1)..pay_date)
        .where("pay_date < :pay_date OR (pay_date = :pay_date AND id < :period_id)",
          pay_date: pay_date, period_id: pay_period.id)
      items = employee.payroll_items.not_voided.where(company_id: company.id, pay_period_id: prior_periods.select(:id))
        .includes({ pay_period: :company }, { payroll_item_field_entries: :payroll_field_definition },
                  payroll_item_deductions: :deduction_type).to_a
      # A draft/current check is absent from the prior committed scope. Include
      # its components once; voided/superseded checks contribute no YTD money.
      items << payroll_item if !payroll_item.voided? && pay_period.correction_status.in?([ nil, "correction" ])
      items
    end
  end

  def ytd_payroll_field_totals
    @ytd_payroll_field_totals ||= begin
      keys = payroll_item.payroll_item_field_entries.select(&:active?)
        .map { |entry| [ entry.label, entry.tax_treatment, entry.category ] }.uniq
      ytd_source_items.each_with_object(Hash.new(0.to_d)) do |item, totals|
        item.payroll_item_field_entries.each do |entry|
          next unless entry.active?

          key = [ entry.label, entry.tax_treatment, entry.category ]
          totals[key] += entry.amount.to_d if keys.include?(key)
        end
      end
    end
  end

  def employee_ytd_totals
    @employee_ytd_totals ||= begin
      year = payroll_item.pay_period.pay_date&.year || Date.current.year
      payroll_item.employee.ytd_totals_through(
        year: year,
        pay_date: payroll_item.pay_period.pay_date,
        pay_period_id: payroll_item.pay_period_id
      )
    end
  end

  def employee_ytd_additional_withholding
    employee_ytd_totals[:additional_withholding].to_d
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
