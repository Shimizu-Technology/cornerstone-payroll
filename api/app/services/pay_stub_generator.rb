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
  # Items saved without earning rows keep the labels their statements have always printed.
  UNSTORED_EARNING_LABELS = {
    "regular" => "Regular",
    "overtime" => "Overtime (1.5x)",
    "holiday" => "Holiday",
    "pto" => "PTO",
    "tips" => "Reported Tips"
  }.freeze

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

    # Keep current and YTD summaries together when the statement paginates.
    render_summaries(pdf)

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

  # The printed statement as data, for readers that must agree with the paper
  # copy (the AIRE worker app). Every row comes from the same builders the PDF
  # renders, so labels and amounts match. Employer-only amounts are omitted.
  def statement
    {
      earnings: statement_earnings,
      taxes: employee.contractor? ? [] : tax_lines.map { |label, amount, ytd| { label: label, amount: amount.to_d, ytd: ytd.to_d } },
      deductions: statement_ytd_breakdown.deductions.map { |row| { label: pay_stub_deduction_label(row), amount: row.current.to_d, ytd: row.ytd.to_d } },
      other_pay: statement_ytd_breakdown.other_pay.map { |row| { label: row.label, amount: row.current.to_d, ytd: row.ytd.to_d } },
      ytd: { gross: pay_ytd_total, net: payroll_item.ytd_net.to_d }
    }
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
    pdf.move_down 6

    pdf.font_size(13) do
      pdf.text "EARNINGS STATEMENT", style: :bold, align: :center
    end
    pdf.move_down 6
  end

  def render_employee_info(pdf)
    pdf.font_size(9) do
      data = [
        [ "Employee:", employee.full_name ],
        [ "Employee ID:", employee.id.to_s ],
        [ "SSN:", "XXX-XX-#{employee.ssn_last_four || '****'}" ],
        [ "Department:", employee.department&.name || "N/A" ]
      ]

      pdf.table(data, cell_style: { borders: [], padding: [ 1, 10, 1, 0 ] }) do
        column(0).font_style = :bold
        column(0).width = 100
      end
    end
    pdf.move_down 6
  end

  def render_pay_period_info(pdf)
    pdf.font_size(9) do
      data = [
        [ "Pay Period:", "#{format_date(pay_period.start_date)} - #{format_date(pay_period.end_date)}" ],
        [ "Pay Date:", format_date(payroll_item.check_date || pay_period.pay_date) ],
        if !payroll_item.net_pay.to_d.positive?
          [ "Payment:", "Earnings statement only - no payment issued" ]
        elsif payroll_item.effective_payment_delivery_method == "direct_deposit"
          [ "Payment:", "Direct deposit (stub only; transfer not confirmed)" ]
        else
          [ "Check #:", payroll_item.check_number.presence || "No check issued" ]
        end
      ]
      if !payroll_item.net_pay.to_d.positive? && payroll_item.check_number.present?
        data << [ "Check reference:", payroll_item.check_number ]
      end

      pdf.table(data, cell_style: { borders: [], padding: [ 1, 10, 1, 0 ] }) do
        column(0).font_style = :bold
        column(0).width = 100
      end
    end
    pdf.move_down 6
  end

  def render_earnings(pdf)
    pdf.font_size(10) do
      pdf.text "EARNINGS", style: :bold
    end
    pdf.move_down 3

    earnings_data = [ [ "Description", "Hours", "Rate", "Current", "YTD" ] ]
    earnings_data.concat(itemized_earnings_rows&.map { |row| itemized_earnings_row(row) } || unitemized_earnings_rows)

    # Gross total
    earnings_data << [
      { content: "GROSS PAY", font_style: :bold },
      "",
      "",
      { content: format_currency(payroll_item.gross_pay), font_style: :bold },
      { content: format_currency(pay_ytd_total), font_style: :bold }
    ]

    pdf.font_size(8) do
      # Long source descriptions wrap in their own column; never squeeze a
      # currency value or its decimal onto a second line to accommodate them.
      pdf.table(earnings_data, header: true, width: pdf.bounds.width,
        column_widths: [ pdf.bounds.width - 278, 46, 64, 80, 88 ]) do
        row(0).font_style = :bold
        row(0).background_color = "EEEEEE"
        cells.padding = [ 2, 6 ]
        columns(1..4).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end

    pdf.move_down 6
  end

  # Each row's YTD prints only when the rows account for both printed totals and
  # every contributing paycheck can be attributed. Anything less keeps "—":
  # a correction without stored rows, an opening balance that was not itemized,
  # stored rows that omit saved earnings, a pay basis that cannot be established,
  # or payroll fields whose identity would merge into one row.
  def itemized_earnings_rows
    return if SignedCorrectionEarnings.call(payroll_item)

    rows = earnings_ytd_breakdown.call
    return unless rows.sum(0.to_d, &:current) == payroll_item.gross_pay.to_d.round(2)
    return unless rows.sum(0.to_d, &:ytd) == pay_ytd_total
    return if rows.any? { |row| row.current.nonzero? && row.ytd.zero? }
    return unless [ payroll_item, *ytd_source_items ].uniq.all? { |item| earnings_attributable?(item) }
    return unless payroll_field_rows_attributable?(rows)

    rows.reject { |row| row.current.zero? && row.ytd.zero? }.presence
  end

  def earnings_attributable?(item)
    stored = item.payroll_item_earnings.reject { |earning| earning.category.to_s == "non_taxable" }
    stored.any? ? stored_earnings_cover_item?(item, stored) : unstored_pay_basis_established?(item)
  end

  # Offsetting omissions can still foot, so compare each saved earning field too.
  def stored_earnings_cover_item?(item, stored)
    expected = {
      "bonus" => item.bonus,
      "tips" => item.reported_tips,
      "service_charge" => item.service_charge_wages,
      "other" => Array(item.custom_earnings).sum(0.to_d) { |entry| entry["amount"].to_d } +
        item.taxable_payroll_adjustments_total.to_d + item.taxable_payroll_field_entries_total.to_d
    }
    expected.all? do |category, amount|
      stored.select { |earning| earning.category.to_s == category }.sum(0.to_d) { |earning| earning.amount.to_d } == amount.to_d.round(2)
    end
  end

  # Reconstruction reads today's profile, so a contractor item needs a saved
  # basis that still agrees with it. A positive override is a fee, not hours.
  def unstored_pay_basis_established?(item)
    return false unless item.contractor? == employee.contractor?
    return true unless item.contractor?

    snapshot = item.calculation_context_snapshot.to_h["employee"]
    saved_pay_type = snapshot["contractor_pay_type"] if snapshot.is_a?(Hash)
    return false unless saved_pay_type.present? && saved_pay_type == employee.contractor_pay_type

    !employee.contractor_hourly? || !item.salary_override.to_d.positive?
  end

  # Field mirrors are saved by label alone. Print one only when its row holds
  # exactly that field's own amounts under a single label/treatment/category.
  def payroll_field_rows_attributable?(rows)
    entries = ytd_source_items.flat_map { |item| item.payroll_item_field_entries.select { |entry| entry.active? && entry.taxable_addition? } }
    entries.group_by(&:label).all? do |label, same_label|
      next false if same_label.map { |entry| [ entry.tax_treatment, entry.category ] }.uniq.many?

      total = same_label.sum(0.to_d) { |entry| entry.amount.to_d }.round(2)
      matching = rows.select { |row| row.source_label == label && row.category.to_s == "other" }
      matching.empty? ? total.zero? : matching.one? && matching.first.ytd == total
    end
  end

  def itemized_earnings_row(row)
    [
      itemized_earning_label(row),
      row.hours.present? ? format_hours(row.hours) : "—",
      itemized_earning_rate(row),
      format_currency(row.current),
      format_currency(row.ytd)
    ]
  end

  def itemized_earning_label(row)
    source_label = source_earning_labels.call(row.source_label)
    return source_label if source_label

    if row.current.nonzero? && !stored_earning_rows?
      UNSTORED_EARNING_LABELS.fetch(row.category.to_s) { row.source_label }
    else
      row.source_label.presence || row.category.to_s.titleize
    end
  end

  def itemized_earning_rate(row)
    return format_currency(row.rate) if row.rate.present?

    pay_basis = fallback_pay_basis(row)
    pay_basis ? printed_rate(payroll_item.pay_rate, pay_basis) : "—"
  end

  # A reconstructed salary or contract-fee row has no stored rate; the stub
  # prints the paycheck's own pay rate on its pay basis instead.
  def fallback_pay_basis(row)
    return if row.current.zero? || stored_earning_rows?

    { "salary" => "salary", "contract_fee" => "contractor" }[row.category.to_s]
  end

  def printed_rate(rate, pay_basis)
    return "—" if rate.nil? && pay_basis.nil?

    pay_basis == "salary" ? "#{format_currency(rate)}/yr" : format_currency(rate)
  end

  def stored_earning_rows?
    payroll_item.payroll_item_earnings.any? { |earning| earning.category.to_s != "non_taxable" }
  end

  # Earning lines as printed, in print order, including YTD-only rows (a zero
  # current amount with earlier pay this year). YTD is nil wherever the PDF
  # prints "—" because the year cannot be attributed row by row. The rate is
  # the one printed; pay_basis is set where that rate is the paycheck's own
  # salary ("salary", printed per year) or contract fee ("contractor").
  def statement_earnings
    lines = if (rows = itemized_earnings_rows)
      rows.map do |row|
        pay_basis = fallback_pay_basis(row) unless row.rate.present?
        { label: itemized_earning_label(row), hours: row.hours, rate: pay_basis ? payroll_item.pay_rate : row.rate,
          pay_basis: pay_basis, amount: row.current, ytd: row.ytd, category: row.category }
      end
    else
      unitemized_earning_lines
    end
    lines.map { |line| line.slice(:label, :hours, :rate, :pay_basis, :amount, :ytd).merge(kind: statement_earning_kind(line[:category])) }
  end

  def statement_earning_kind(category)
    case category.to_s
    when "regular", "salary", "contract_fee" then "regular"
    when "overtime", "holiday", "pto", "bonus" then category.to_s
    else "other"
    end
  end

  def unitemized_earnings_rows
    unitemized_earning_lines.map do |line|
      [
        line[:label],
        line[:hours].nil? ? "—" : format_hours(line[:hours]),
        printed_rate(line[:rate], line[:pay_basis]),
        format_currency(line[:amount]),
        line[:ytd].nil? ? "—" : format_currency(line[:ytd])
      ]
    end
  end

  def earning_line(label, hours, rate, amount, category, pay_basis: nil, ytd: nil)
    { label: label, hours: hours, rate: rate, pay_basis: pay_basis, amount: amount, category: category, ytd: ytd }
  end

  def unitemized_earning_lines
    earnings_data = []

    # Non-taxable earnings are printed in their own section because they increase
    # net pay but are intentionally excluded from gross pay.
    item_earnings = payroll_item.payroll_item_earnings.reject { |earning| earning.category.to_s == "non_taxable" }
    correction_earnings = SignedCorrectionEarnings.call(payroll_item)
    # Calculators materialize each taxable field as an `other` earning. Prefer
    # the field row below, which also carries its field-specific YTD. Consume
    # one matching mirror per field; equal labels alone are not identity.
    payroll_field_entries_for("taxable_addition").each do |entry|
      next unless entry.amount.to_d.positive?

      index = item_earnings.rindex do |earning|
        earning.category == "other" && earning.label.to_s.strip.casecmp?(entry.label.to_s.strip) &&
          earning.amount.to_d.round(2) == entry.amount.to_d.round(2)
      end
      item_earnings.delete_at(index) if index
    end

    if payroll_item.payroll_item_earnings.any? { |earning| earning.category.to_s != "non_taxable" }
      item_earnings.each do |earning|
        earnings_data << earning_line(source_earning_labels.call(earning.label) || earning.label.presence || earning.category.to_s.titleize,
          earning.hours.presence, earning.rate.presence, earning.amount, earning.category)
      end
    elsif correction_earnings
      correction_earnings.each do |earning|
        earnings_data << earning_line(earning.label, earning.hours, earning.rate, earning.amount, nil)
      end
    elsif payroll_item.hourly? || (payroll_item.employee.contractor_hourly? &&
        payroll_item.salary_override.to_d <= 0 && payroll_item.total_hours.to_d.positive?)
      # Regular pay
      if payroll_item.hours_worked.to_f > 0
        earnings_data << earning_line("Regular", payroll_item.hours_worked, payroll_item.pay_rate,
          payroll_item.hours_worked.to_d * payroll_item.pay_rate.to_d, "regular")
      end

      # Overtime
      if payroll_item.overtime_hours.to_f > 0
        overtime_rate = payroll_item.pay_rate.to_d * BigDecimal("1.5")
        earnings_data << earning_line("Overtime (1.5x)", payroll_item.overtime_hours, overtime_rate,
          payroll_item.overtime_hours.to_d * overtime_rate, "overtime")
      end

      # Holiday
      if payroll_item.holiday_hours.to_f > 0
        earnings_data << earning_line("Holiday", payroll_item.holiday_hours, payroll_item.pay_rate,
          payroll_item.holiday_hours.to_d * payroll_item.pay_rate.to_d, "holiday")
      end

      # PTO
      if payroll_item.pto_hours.to_f > 0
        earnings_data << earning_line("PTO", payroll_item.pto_hours, payroll_item.pay_rate,
          payroll_item.pto_hours.to_d * payroll_item.pay_rate.to_d, "pto")
      end
    else
      # Subtract separately displayed taxable additions from the legacy base pay.
      ce_total = Array(payroll_item.custom_earnings).sum(0.to_d) { |ce| ce["amount"].to_d } + payroll_item.taxable_payroll_adjustments_total.to_d
      contractor = payroll_item.employee.contractor?
      earnings_data << earning_line(contractor ? "Contract Fee" : "Salary", nil, payroll_item.pay_rate,
        payroll_item.gross_pay.to_d - payroll_item.bonus.to_d - payroll_item.reported_tips.to_d -
          payroll_item.service_charge_wages.to_d - ce_total - payroll_item.taxable_payroll_field_entries_total.to_d,
        contractor ? "contract_fee" : "salary", pay_basis: contractor ? "contractor" : "salary")
    end

    if correction_earnings.nil?
      existing_earning_categories = item_earnings.map { |earning| earning.category.to_s }
      existing_other_labels = item_earnings
        .select { |earning| earning.category.to_s == "other" }
        .map { |earning| earning.label.to_s.strip.downcase }

      # Bonus
      if payroll_item.bonus.to_f > 0 && !existing_earning_categories.include?("bonus")
        earnings_data << earning_line("Bonus", nil, nil, payroll_item.bonus, "bonus")
      end

      # Tips
      if payroll_item.reported_tips.to_f > 0 && !existing_earning_categories.include?("tips")
        earnings_data << earning_line("Reported Tips", nil, nil, payroll_item.reported_tips, "tips")
      end

      if payroll_item.service_charge_wages.to_f.nonzero? && !existing_earning_categories.include?("service_charge")
        earnings_data << earning_line("Service Charges", nil, nil, payroll_item.service_charge_wages, "service_charge")
      end

      # Custom earnings (e.g. Chief Stipend, Asst Chief Stipend)
      Array(payroll_item.custom_earnings).each do |ce|
        label = ce["label"].presence || "Other Earning"
        amt = ce["amount"].to_d
        if amt > 0 && !existing_other_labels.include?(label.to_s.strip.downcase)
          earnings_data << earning_line(label, nil, nil, amt, "other")
        end
      end

      payroll_item.active_payroll_adjustments.each do |adjustment|
        next unless adjustment["treatment"] == "taxable_addition"

        label = adjustment["label"].presence || "Taxable Adjustment"
        amount = adjustment["amount"].to_d
        if amount > 0 && !existing_other_labels.include?(label.to_s.strip.downcase)
          earnings_data << earning_line(label, nil, nil, amount, "other")
        end
      end

      payroll_field_entries_for("taxable_addition").each do |entry|
        earnings_data << earning_line(entry.label, nil, nil, entry.amount, "other", ytd: ytd_payroll_field_amount(entry)) if entry.amount.to_f.positive?
      end

    end

    earnings_data
  end

  def render_deductions(pdf)
    pdf.font_size(10) do
      pdf.text "DEDUCTIONS", style: :bold
    end
    pdf.move_down 3

    deductions_data = [ [ "Description", "Current", "YTD" ] ]

    taxes = tax_lines
    taxes.first(3).each { |label, amount, ytd| deductions_data << [ label, format_currency(amount), format_currency(ytd) ] }

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

    taxes.drop(3).each { |label, amount, ytd| deductions_data << [ label, format_currency(amount), format_currency(ytd) ] }

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
        cells.padding = [ 2, 6 ]
        columns(1..2).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end

    pdf.move_down 6
  end

  # Employee taxes as printed: income tax, Social Security and Medicare always,
  # then W-4 4c additional withholding when it has a current or YTD amount.
  def tax_lines
    lines = [
      [ "Federal/Guam Income Tax", payroll_item.withholding_tax, payroll_item.ytd_withholding_tax ],
      [ "Social Security (6.2%)", payroll_item.social_security_tax, payroll_item.ytd_social_security_tax ],
      [ "Medicare (1.45%)", payroll_item.medicare_tax, payroll_item.ytd_medicare_tax ]
    ]
    ytd_addl = employee_ytd_additional_withholding
    if payroll_item.additional_withholding.to_d.nonzero? || ytd_addl.nonzero?
      lines << [ "Additional Withholding (W-4 4c)", payroll_item.additional_withholding, ytd_addl ]
    end
    lines
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
        cells.padding = [ 2, 6 ]
        columns(1..2).align = :right
      end
    end

    pdf.move_down 6
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
        cells.padding = [ 2, 6 ]
        columns(1..2).align = :right
        row(-1).background_color = "F5F5F5"
      end
    end

    pdf.move_down 6
  end

  def render_summaries(pdf)
    additions = statement_ytd_breakdown.other_pay.sum(0.to_d) { |row| row.current.to_d }
    deductions = statement_ytd_breakdown.deductions.sum(0.to_d) { |row| row.current.to_d }
    taxes = payroll_item.withholding_tax.to_d + payroll_item.additional_withholding.to_d +
      payroll_item.social_security_tax.to_d + payroll_item.medicare_tax.to_d
    data = [
      [ "SUMMARY", "Current" ],
      [ "Gross Pay", format_currency(payroll_item.gross_pay) ],
      [ "Non-Taxable Pay", format_currency(additions) ],
      [ "Taxes", format_currency(taxes) ],
      [ "Deductions", format_currency(deductions) ],
      [ "NET PAY", format_currency(payroll_item.net_pay) ]
    ]
    pdf.font_size(8) do
      table = pdf.make_table(data, width: 250, position: :right) do
        cells.padding = [ 2, 8 ]
        column(1).align = :right
        row(0).font_style = :bold
        row(-1).font_style = :bold
        row(-1).background_color = "E8F5E9"
      end
      ytd_table = ytd_summary_table(pdf)
      heading_height = pdf.height_of("YEAR-TO-DATE SUMMARY", size: 10, style: :bold)
      summary_height = table.height + 6 + heading_height + 3 + ytd_table.height
      pdf.start_new_page if pdf.cursor < summary_height
      table.draw
      pdf.move_down 6
      pdf.text "YEAR-TO-DATE SUMMARY", size: 10, style: :bold
      pdf.move_down 3
      ytd_table.draw
    end
  end

  def ytd_summary_table(pdf)
    ytd_data = [
      [ "Gross Earnings", format_currency(pay_ytd_total) ],
      [ "Non-Taxable Pay", format_currency(statement_ytd_breakdown.other_pay.sum(0.to_d) { |row| row.ytd.to_d }) ],
      [ "Federal/Guam Tax", format_currency(payroll_item.ytd_withholding_tax) ],
      [ "Social Security", format_currency(payroll_item.ytd_social_security_tax) ],
      [ "Medicare", format_currency(payroll_item.ytd_medicare_tax) ],
      [ "Deductions", format_currency(statement_ytd_breakdown.deductions.sum(0.to_d) { |row| row.ytd.to_d }) ],
      [ "Net Pay", format_currency(payroll_item.ytd_net) ]
    ]

    if employee_ytd_additional_withholding.nonzero?
      ytd_data.insert(3, [ "Additional Withholding", format_currency(employee_ytd_additional_withholding) ])
    end

    pdf.make_table(ytd_data, width: 250) do
      cells.padding = [ 2, 6 ]
      cells.borders = []
      column(0).font_style = :bold
      column(1).align = :right
      row(-1).background_color = "F5F5F5"
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
        pay_period_id: pay_period.id,
        for_reporting: true
      )
      gross = totals.fetch(:gross_pay).to_d + payroll_item.gross_pay.to_d
      earnings_ytd_breakdown.pay_ytd_total(gross)
    end
  end

  def earnings_ytd_breakdown
    @earnings_ytd_breakdown ||= PayrollEarningsYtdBreakdown.new(payroll_item)
  end

  def source_earning_labels
    @source_earning_labels ||= PayrollSourceEarningLabel.new(payroll_item, source_items: earnings_ytd_breakdown.source_items)
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
      items = employee.payroll_items.financially_reportable.where(company_id: company.id, pay_period_id: prior_periods.select(:id))
        .includes({ pay_period: :company }, :payroll_item_earnings, { payroll_item_field_entries: :payroll_field_definition },
                  payroll_item_deductions: :deduction_type).to_a
      # A draft/current check is absent from the prior committed scope. Include
      # its components once; financially reversed payroll contributes no YTD money.
      items << payroll_item if payroll_item.payroll_included? && pay_period.correction_status.in?([ nil, "correction" ])
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
      payroll_item.employee.ytd_totals_before(
        year: year,
        pay_date: payroll_item.pay_period.pay_date,
        pay_period_id: payroll_item.pay_period_id,
        for_reporting: true
      )
    end
  end

  def employee_ytd_additional_withholding
    current = if payroll_item.payroll_included? && pay_period.correction_status.in?([ nil, "correction" ])
      payroll_item.additional_withholding.to_d
    else
      0.to_d
    end
    employee_ytd_totals[:additional_withholding].to_d + current
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
