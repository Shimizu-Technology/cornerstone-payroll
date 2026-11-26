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

  def initialize(payroll_item, preview: false, employee_copy: false)
    @preview = preview
    @employee_copy = employee_copy
    @payroll_item = payroll_item
    @employee = payroll_item.employee
    @pay_period = payroll_item.pay_period
    @company = pay_period.company
  end

  def generate
    pdf = PdfUnicodeFont.document(page_size: "LETTER", margin: [ 32, 32, 64, 32 ])

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

    PdfPreviewWatermark.apply(pdf) if @preview
    render_with_footer(
      pdf,
      @preview ? "PREVIEW" : "This is your official earnings statement. Please retain for your records.\nGenerated on #{guam_generated_timestamp}",
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
      taxes: tax_lines.map { |label, amount, ytd| { label: label, amount: amount.to_d, ytd: ytd } },
      deductions: statement_ytd_breakdown.deductions.map { |row| { label: pay_stub_deduction_label(row), amount: row.current.to_d, ytd: row.ytd.to_d } },
      other_pay: statement_ytd_breakdown.other_pay.map { |row| { label: row.label, amount: row.current.to_d, ytd: row.ytd.to_d } },
      ytd: { gross: pay_ytd_total, net: statement_ytd_totals[:net] }
    }
  end

  # The printed legal name, this check's facts, and every printed YTD amount. A later
  # change to an earlier check revises this statement only when it changes a
  # printed YTD amount. Current rows use their own labels, so a relabelled YTD
  # attribution alone does not.
  def employee_payroll_facts_sha256
    @employee_payroll_facts_sha256 ||= employee_payroll_fingerprint
  end

  def matches_employee_payroll_facts?(digest)
    digest.present? && (digest == employee_payroll_facts_sha256 || digest == employee_payroll_fingerprint(legacy: true))
  end

  def self.employee_payment_line(item)
    if !item.net_pay.to_d.positive?
      [ "Earnings statement only - no payment issued", item.check_number.presence ].compact.join(" · ")
    elsif item.effective_payment_delivery_method == "direct_deposit"
      "Direct deposit"
    else
      "Check ##{item.check_number}"
    end
  end

  private

  # Reproduce the old tax payload to compare existing frozen PDFs. The legacy
  # comparison includes combined Medicare, the only Medicare figure they printed.
  def employee_payroll_fingerprint(legacy: false)
    ytd_source_items
    Digest::SHA256.hexdigest([ employee.legal_name, *employee_payroll_current_facts(legacy: legacy), printed_ytd_facts(legacy: legacy) ].to_json)
  end

  def employee_payroll_current_facts(legacy:)
    earnings = unitemized_earning_lines(source_labels: PayrollSourceEarningLabel.new(payroll_item), include_ytd: false)
      .map { |line| line.except(:ytd) }
    components = PayrollStatementYtdBreakdown::KINDS.map do |kind|
      statement_ytd_breakdown.current_rows(kind).map { |row| [ row.label, row.current, row.semantic ] }
    end
    amounts = payroll_item.attributes.slice(
      "gross_pay", "net_pay", "withholding_tax", "withholding_tax_override", "withholding_tax_adjustment",
      "social_security_tax", "medicare_tax", "additional_withholding"
    )
    amounts["additional_medicare_tax"] = payroll_item.additional_medicare_tax.to_d unless legacy || payroll_item.contractor?
    [
      pay_period.start_date, pay_period.end_date, pay_period.pay_date, payroll_item.check_date,
      self.class.employee_payment_line(payroll_item), amounts, earnings, components
    ]
  end

  def printed_ytd_facts(legacy:)
    fact = ->(amount) { amount&.to_d&.round(2)&.to_s("F") }
    rows = ->(list) { list.map { |row| [ row.label, fact.call(row.ytd) ] } }
    {
      earnings: printed_earning_ytds.map { |ytd| fact.call(ytd) },
      taxes: tax_facts(legacy: legacy).map { |key, _amount, ytd| [ key, fact.call(ytd) ] },
      deductions: rows.call(statement_ytd_breakdown.deductions),
      other_pay: rows.call(statement_ytd_breakdown.other_pay),
      employer_contributions: rows.call(statement_ytd_breakdown.employer_contributions),
      gross: fact.call(pay_ytd_total),
      net: fact.call(statement_ytd_totals[:net])
    }
  end

  # The earnings YTD column as statement_earnings prints it, without resolving
  # the display labels, which the YTD amounts never depend on.
  def printed_earning_ytds
    rows = itemized_earnings_rows
    return rows.map(&:ytd) if rows

    unitemized_earning_lines(source_labels: ->(_label) { }).map { |line| line[:ytd] }
  end

  def render_header(pdf)
    pdf.font_size(16) do
      pdf.text company.name, style: :bold
    end

    header_lines = [ *company.full_address.lines(chomp: true), company.phone ].compact_blank
    if header_lines.any?
      pdf.font_size(9) do
        header_lines.each { |line| pdf.text line }
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
        [ "Employee:", employee.legal_name ],
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
        if @employee_copy && !@preview
          [ "Payment:", self.class.employee_payment_line(payroll_item) ]
        elsif !payroll_item.net_pay.to_d.positive?
          [ "Payment:", @preview ? "Earnings statement only" : "Earnings statement only - no payment issued" ]
        elsif payroll_item.effective_payment_delivery_method == "direct_deposit"
          [ "Payment:", @preview ? "Direct deposit" : "Direct deposit (stub only; transfer not confirmed)" ]
        else
          [ "Check #:", @preview ? "" : payroll_item.check_number.presence || "No check issued" ]
        end
      ]
      if !@preview && !@employee_copy && !payroll_item.net_pay.to_d.positive? && payroll_item.check_number.present?
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
    earnings_data.concat(printable_earning_rows)

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

  def itemized_earnings_rows
    earnings_ytd_breakdown.attributable_rows
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
    return row.label if row.historical_only && row.source_label.to_s.strip.casecmp?("regular")

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

  def unitemized_earning_lines(source_labels: source_earning_labels, include_ytd: true)
    earnings_data = []

    # Non-taxable earnings are printed in their own section because they increase
    # net pay but are intentionally excluded from gross pay.
    item_earnings = payroll_item.earnings_in_entry_order.reject { |earning| earning.category.to_s == "non_taxable" }
    has_stored_earnings = item_earnings.any?
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

    if has_stored_earnings
      item_earnings.each do |earning|
        earnings_data << earning_line(source_labels.call(earning.label) || earning.label.presence || earning.category.to_s.titleize,
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
        earnings_data << earning_line(entry.label, nil, nil, entry.amount, "other", ytd: (ytd_payroll_field_amount(entry) if include_ytd)) if entry.amount.to_f.positive?
      end

    end

    earnings_data
  end

  def printable_earning_rows
    itemized_earnings_rows&.map { |row| itemized_earnings_row(row) } || unitemized_earnings_rows
  end

  def printable_deduction_rows
    deductions_data = []

    taxes = tax_lines.map { |label, amount, ytd| [ label, format_currency(amount), (format_currency(ytd) if ytd) ] }
    deductions_data << taxes.first if taxes.any?

    if taxes.empty?
      # A contractor statement prints no tax rows or notes.
    elsif payroll_item.withholding_tax_override.present?
      deductions_data << [
        "  (Final #{PayrollLabels::INCOME_TAX} override applied)",
        "",
        ""
      ]
    elsif payroll_item.withholding_tax_adjustment.to_f.nonzero?
      deductions_data << [
        format("  (#{PayrollLabels::INCOME_TAX} adjustment %s%s)", payroll_item.withholding_tax_adjustment.to_f.positive? ? "+" : "", format_currency(payroll_item.withholding_tax_adjustment).delete("$")),
        "",
        ""
      ]
    end

    deductions_data.concat(taxes.drop(1))

    statement_ytd_breakdown.deductions.each do |row|
      deductions_data << [ pay_stub_deduction_label(row), format_currency(row.current), format_currency(row.ytd) ]
    end

    deductions_data
  end

  def render_deductions(pdf)
    pdf.font_size(10) do
      pdf.text "DEDUCTIONS", style: :bold
    end
    pdf.move_down 3
    deductions_data = [ [ "Description", "Current", "YTD" ], *printable_deduction_rows ]

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
  # A contractor paycheck has no employee taxes, on paper or in the employee
  # app. The paycheck's saved type decides, not the worker's current one.
  def tax_lines
    tax_facts.map { |key, amount, ytd| [ PayrollLabels::STUB_TAXES.fetch(key), amount, ytd ] }
  end

  LEGACY_TAX_LABELS = {
    income_tax: "Federal/Guam Income Tax",
    social_security: "Social Security (6.2%)",
    medicare: "Medicare (1.45%)",
    additional_withholding: "Additional Withholding (W-4 4c)"
  }.freeze

  def tax_facts(legacy: false)
    return [] if payroll_item.contractor?

    lines = [
      [ :income_tax, payroll_item.withholding_tax, statement_ytd_totals[:withholding_tax] ],
      [ :social_security, payroll_item.social_security_tax, statement_ytd_totals[:social_security_tax] ]
    ]
    medicare_ytd = statement_ytd_totals[:medicare_tax]
    if legacy
      lines << [ :medicare, payroll_item.medicare_tax, medicare_ytd ]
    else
      additional = payroll_item.additional_medicare_tax.to_d
      additional_ytd = ytd_sources.additional_medicare_ytd
      lines << [ :medicare, payroll_item.medicare_tax.to_d - additional, medicare_ytd - additional_ytd.to_d ]
      lines << [ :additional_medicare, additional, additional_ytd ] if additional.nonzero? || additional_ytd.to_d.nonzero?
    end

    ytd_additional = statement_ytd_totals[:additional_withholding]
    if payroll_item.additional_withholding.to_d.nonzero? || ytd_additional.nonzero?
      lines << [ :additional_withholding, payroll_item.additional_withholding, ytd_additional ]
    end
    return lines unless legacy

    lines.map { |key, amount, ytd| [ LEGACY_TAX_LABELS.fetch(key), amount, ytd ] }
  end

  def printable_addition_rows
    statement_ytd_breakdown.other_pay.map { |row| [ row.label, format_currency(row.current), format_currency(row.ytd) ] }
  end

  def printable_employer_rows
    statement_ytd_breakdown.employer_contributions.map { |row| [ row.label, format_currency(row.current), format_currency(row.ytd) ] }
  end

  def render_non_taxable_additions(pdf)
    additions = printable_addition_rows

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

    rows = [ [ "Description", "Current", "YTD" ], *printable_employer_rows ]
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
    tax_rows = tax_facts.filter_map do |key, _current, ytd|
      next if ytd.nil? || (key == :additional_withholding && ytd.zero?)

      label = key == :social_security ? "Social Security" : PayrollLabels::STUB_TAXES.fetch(key)
      [ label, format_currency(ytd) ]
    end
    ytd_data = [
      [ "Gross Earnings", format_currency(pay_ytd_total) ],
      [ "Non-Taxable Pay", format_currency(statement_ytd_breakdown.other_pay.sum(0.to_d) { |row| row.ytd.to_d }) ],
      *tax_rows,
      [ "Deductions", format_currency(statement_ytd_breakdown.deductions.sum(0.to_d) { |row| row.ytd.to_d }) ],
      [ "Net Pay", format_currency(statement_ytd_totals[:net]) ]
    ]

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
    @pay_ytd_total ||= earnings_ytd_breakdown.pay_ytd_total(statement_ytd_totals[:gross])
  end

  def statement_ytd_totals
    ytd_sources.totals
  end

  def ytd_sources
    @ytd_sources ||= PayrollStatementYtdSources.new(payroll_item)
  end

  def earnings_ytd_breakdown
    @earnings_ytd_breakdown ||= PayrollEarningsYtdBreakdown.new(payroll_item, sources: ytd_sources)
  end

  def source_earning_labels
    @source_earning_labels ||= PayrollSourceEarningLabel.new(payroll_item, source_items: ytd_source_items)
  end

  def payroll_field_entries_for(*treatments)
    payroll_item.payroll_field_entries_for_calculation.select { |entry| entry.active? && treatments.include?(entry.tax_treatment) }
  end

  def ytd_payroll_field_amount(entry)
    ytd_payroll_field_totals.fetch([ entry.label, entry.tax_treatment, entry.category ], 0.to_d)
  end

  def ytd_total_deductions
    statement_ytd_totals.values_at(:withholding_tax, :social_security_tax, :medicare_tax, :additional_withholding).sum +
      statement_ytd_breakdown.deductions.sum(0.to_d) { |row| row.ytd.to_d }
  end

  def current_total_deductions
    payroll_item.withholding_tax.to_d + payroll_item.social_security_tax.to_d + payroll_item.medicare_tax.to_d +
      payroll_item.additional_withholding.to_d + statement_ytd_breakdown.deductions.sum(0.to_d) { |row| row.current.to_d }
  end

  def statement_ytd_breakdown
    @statement_ytd_breakdown ||= PayrollStatementYtdBreakdown.new(payroll_item, sources: ytd_sources)
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

  # The same earlier and current paychecks as the statement's YTD rows.
  def ytd_source_items
    ytd_sources.items
  end

  def ytd_payroll_field_totals
    @ytd_payroll_field_totals ||= begin
      keys = payroll_item.payroll_field_entries_for_calculation.select(&:active?)
        .map { |entry| [ entry.label, entry.tax_treatment, entry.category ] }.uniq
      ytd_source_items.each_with_object(Hash.new(0.to_d)) do |item, totals|
        item.payroll_field_entries_for_calculation.each do |entry|
          next unless entry.active?

          key = [ entry.label, entry.tax_treatment, entry.category ]
          totals[key] += entry.amount.to_d if keys.include?(key)
        end
      end
    end
  end

  def format_currency(amount)
    MoneyText.currency(amount)
  end

  def format_hours(hours)
    return "0.00" if hours.nil?
    sprintf("%.2f", hours.to_f)
  end

  def format_date(date)
    date.strftime("%m/%d/%Y")
  end
end
