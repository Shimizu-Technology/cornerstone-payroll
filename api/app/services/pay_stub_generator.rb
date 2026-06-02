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
    if payroll_item.insurance_payment.to_f > 0 && payroll_field_entries_for("pre_tax_deduction", "post_tax_deduction").none? { |entry| entry.category == "insurance" }
      deductions_data << [
        "Health Insurance",
        format_currency(payroll_item.insurance_payment),
        format_currency(visible_legacy_insurance_ytd)
      ]
    end

    # Loan
    if payroll_item.loan_payment.to_f > 0 && payroll_field_entries_for("pre_tax_deduction", "post_tax_deduction").none? { |entry| entry.category == "loan" }
      deductions_data << [
        "Loan Repayment",
        format_currency(payroll_item.loan_payment),
        format_currency(visible_legacy_loan_ytd)
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

    payroll_item.active_payroll_adjustments.each do |adjustment|
      next unless %w[pre_tax_deduction post_tax_deduction].include?(adjustment["treatment"])

      amount = adjustment["amount"].to_f
      next unless amount.positive?

      deductions_data << [
        adjustment["label"].presence || "Payroll Adjustment",
        format_currency(amount),
        "—"
      ]
    end

    payroll_field_entries_for("pre_tax_deduction", "post_tax_deduction").each do |entry|
      deductions_data << [ entry.label, format_currency(entry.amount), format_currency(ytd_payroll_field_amount(entry)) ] if entry.amount.to_f.positive?
    end

    # Total deductions
    deductions_data << [
      { content: "TOTAL DEDUCTIONS", font_style: :bold },
      { content: format_currency(payroll_item.total_deductions), font_style: :bold },
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
    additions = []
    if payroll_item.non_taxable_pay.to_f > 0
      additions << [ "Non-Taxable Pay", format_currency(payroll_item.non_taxable_pay), "—" ]
    end

    payroll_item.active_payroll_adjustments.each do |adjustment|
      next unless adjustment["treatment"] == "non_taxable_addition"

      amount = adjustment["amount"].to_f
      next unless amount.positive?

      additions << [ adjustment["label"].presence || "Non-Taxable Addition", format_currency(amount), "—" ]
    end

    payroll_field_entries_for("non_taxable_addition").each do |entry|
      additions << [ entry.label, format_currency(entry.amount), format_currency(ytd_payroll_field_amount(entry)) ] if entry.amount.to_f.positive?
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
    entries = payroll_field_entries_for("employer_contribution").select { |entry| entry.amount.to_f.positive? }
    return if entries.empty?

    pdf.font_size(10) do
      pdf.text "EMPLOYER CONTRIBUTIONS", style: :bold
    end
    pdf.move_down 3

    rows = [ [ "Description", "Current", "YTD" ] ] + entries.map { |entry| [ entry.label, format_currency(entry.amount), format_currency(ytd_payroll_field_amount(entry)) ] }
    rows << [
      { content: "TOTAL EMPLOYER CONTRIBUTIONS", font_style: :bold },
      { content: format_currency(entries.sum { |entry| entry.amount.to_f }), font_style: :bold },
      { content: format_currency(entries.sum { |entry| ytd_payroll_field_amount(entry) }), font_style: :bold }
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

  def payroll_field_entries_for(*treatments)
    payroll_item.payroll_item_field_entries.select { |entry| entry.active? && treatments.include?(entry.tax_treatment) }
  end

  def ytd_payroll_field_amount(entry)
    ytd_payroll_field_totals.fetch([ entry.label, entry.tax_treatment, entry.category ], 0.0)
  end

  def ytd_total_deductions
    payroll_item.ytd_withholding_tax.to_f + payroll_item.ytd_social_security_tax.to_f + payroll_item.ytd_medicare_tax.to_f +
      employee_ytd_additional_withholding + payroll_item.ytd_retirement.to_f + payroll_item.ytd_roth_retirement.to_f +
      visible_legacy_insurance_ytd + visible_legacy_loan_ytd + employee_ytd_tips_paid_out +
      employee_ytd_custom_deductions_total + ytd_payroll_field_deductions_total
  end

  def visible_legacy_insurance_ytd
    return 0.0 if payroll_field_entries_for("pre_tax_deduction", "post_tax_deduction").any? { |entry| entry.category == "insurance" }

    employee_ytd_totals[:insurance].to_f
  end

  def visible_legacy_loan_ytd
    return 0.0 if payroll_field_entries_for("pre_tax_deduction", "post_tax_deduction").any? { |entry| entry.category == "loan" }

    employee_ytd_totals[:loans].to_f
  end

  def ytd_payroll_field_deductions_total
    ytd_payroll_field_totals.sum do |(_label, treatment, _category), amount|
      %w[pre_tax_deduction post_tax_deduction].include?(treatment) ? amount.to_f : 0.0
    end
  end

  def ytd_payroll_field_totals
    @ytd_payroll_field_totals ||= begin
      entries = payroll_item.payroll_item_field_entries.select(&:active?)
      keys = entries.map { |entry| [ entry.label, entry.tax_treatment, entry.category ] }.uniq
      if keys.empty?
        {}
      else
        labels = keys.map(&:first).uniq
        treatments = keys.map { |key| key[1] }.uniq
        categories = keys.map { |key| key[2] }.uniq
        pay_date = payroll_item.pay_period.pay_date || Date.current
        year_start = Date.new(pay_date.year, 1, 1)
        raw_totals = PayrollItemFieldEntry.joins(payroll_item: :pay_period)
          .merge(PayrollItem.not_voided)
          .where(payroll_items: { employee_id: employee.id, company_id: payroll_item.company_id })
          .where(pay_periods: { pay_date: year_start..pay_date })
          .where(active: true, label: labels, tax_treatment: treatments, category: categories)
          .where("pay_periods.pay_date < :pay_date OR (pay_periods.pay_date = :pay_date AND pay_periods.id <= :pay_period_id)",
            pay_date: pay_date,
            pay_period_id: payroll_item.pay_period.id)
          .group(:label, :tax_treatment, :category)
          .sum(:amount)

        raw_totals.each_with_object(Hash.new(0.0)) do |((label, treatment, category), amount), totals|
          key = [ label, treatment, category ]
          totals[key] = amount.to_f if keys.include?(key)
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
    employee_ytd_totals[:additional_withholding].to_f
  end

  def employee_ytd_tips_paid_out
    employee_ytd_totals[:tips_paid_out].to_f
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

  def employee_ytd_custom_deductions_total
    @employee_ytd_custom_deductions_total ||= custom_deduction_items.sum do |item|
      item.custom_deductions_total.to_f + item.pre_tax_payroll_adjustments_total.to_f + item.post_tax_payroll_adjustments_total.to_f
    end
  end

  def custom_deduction_items
    year = payroll_item.pay_period.pay_date&.year || Date.current.year

    payroll_item.employee.payroll_items
      .joins(:pay_period)
      .select(:id, :custom_deductions, :payroll_adjustments)
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
