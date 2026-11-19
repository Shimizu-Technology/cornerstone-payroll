# frozen_string_literal: true

module YearEnd
  # Ties a company's W-2GU totals to the four computed Form 941 quarters and the
  # quarterly Guam W-1s, line by line, exactly as each aggregator reports them.
  #
  # Opening summaries (QuickBooks or prior-provider YTD balances without
  # paycheck dates) are in the W-2GU through the YTD bridge but are excluded from
  # every quarterly return, so they are shown as their own column rather than
  # hidden in a difference. Each quarter is also compared with its own payroll
  # records, which names the quarter (or the W-2 report) to look at when the
  # totals disagree.
  class Reconciliation
    TOLERANCE = BigDecimal("0.01")
    QUARTERS = (1..4).freeze

    LINES = [
      { key: "social_security_wages", label: "Social Security wages", w2_box: "Box 3",
        w2_total: :box3_social_security_wages, source: "form_941", source_label: "Form 941 line 5a" },
      { key: "social_security_tips", label: "Social Security tips", w2_box: "Box 7",
        w2_total: :box7_social_security_tips, source: "form_941", source_label: "Form 941 line 5b" },
      { key: "medicare_wages", label: "Medicare wages and tips", w2_box: "Box 5",
        w2_total: :box5_medicare_wages_tips, source: "form_941", source_label: "Form 941 line 5c" },
      { key: "social_security_tax", label: "Social Security tax withheld", w2_box: "Box 4",
        w2_total: :box4_social_security_tax_withheld, source: "form_941", source_label: "Employee Social Security tax on the 941" },
      { key: "medicare_tax", label: "Medicare tax withheld", w2_box: "Box 6",
        w2_total: :box6_medicare_tax_withheld, source: "form_941", source_label: "Employee Medicare tax on the 941" },
      { key: "guam_income_tax", label: "Guam income tax withheld", w2_box: "Box 2",
        w2_total: :box2_federal_income_tax_withheld, source: "w1", source_label: "W-1 Guam withholding" }
    ].freeze

    # The payload when the totals cannot be compared (for example the W-2GU
    # report itself could not be built), so the checklist still blocks.
    def self.unavailable(message)
      {
        status: "unavailable",
        tolerance: TOLERANCE.to_f,
        quarters: [],
        opening_balances: { present: false, first_pay_date: nil, last_pay_date: nil },
        lines: [],
        error: message,
        blockers: [ { code: "RECONCILIATION_UNAVAILABLE", line: nil, message: "The totals could not be compared: #{message}" } ]
      }
    end

    def initialize(company:, year:, w2_report:)
      @company = company
      @year = Integer(year)
      @w2_report = w2_report
    end

    def call
      quarter_values = QUARTERS.index_with { |quarter| filed_quarter_values(quarter) }
      record_values = payroll_record_values
      opening = opening_balance_values
      lines = LINES.map { |line| line_payload(line, quarter_values, record_values, opening) }
      mismatched = lines.reject { |line| line[:status] == "match" }

      {
        status: mismatched.empty? ? "match" : "mismatch",
        tolerance: TOLERANCE.to_f,
        quarters: QUARTERS.map { |quarter| quarter_payload(quarter) },
        opening_balances: {
          present: opening[:present],
          first_pay_date: opening[:first_pay_date]&.iso8601,
          last_pay_date: opening[:last_pay_date]&.iso8601
        },
        lines: lines,
        blockers: mismatched.map do |line|
          { code: "RECONCILIATION_MISMATCH", line: line[:key], message: line[:message] }
        end
      }
    rescue ArgumentError => e
      unavailable(e.message)
    end

    private

    attr_reader :company, :year, :w2_report

    def year_range
      Date.new(year, 1, 1)..Date.new(year, 12, 31)
    end

    def filed_quarter_values(quarter)
      report = Form941GuAggregator.new(company, year, quarter).generate
      lines = report.fetch(:lines)
      detail = report.fetch(:tax_detail)
      {
        "social_security_wages" => lines[:line5a_ss_wages],
        "social_security_tips" => lines[:line5b_ss_tips],
        "medicare_wages" => lines[:line5c_medicare_wages],
        "social_security_tax" => detail[:ss_employee],
        "medicare_tax" => detail[:medicare_employee],
        "guam_income_tax" => QuarterlyCompliancePacketBuilder.new(company, year, quarter).w1_total
      }.transform_values { |value| decimal(value) }
    end

    # One grouped query for committed Cornerstone payroll, plus dated imported
    # records, using the stored bases the W-2GU itself sums.
    def payroll_record_values
      totals = QUARTERS.index_with { Hash.new(0.to_d) }
      native_quarter_rows.each do |row|
        quarter = row["quarter"].to_i
        LINES.each { |line| totals[quarter][line[:key]] += decimal(row[line[:key]]) }
      end
      dated_historical_records.each do |record|
        historical_record_values(record).each { |key, value| totals[quarter_of(record.pay_date)][key] += value }
      end
      totals
    end

    def record_counts
      @record_counts ||= begin
        counts = native_quarter_rows.to_h { |row| [ row["quarter"].to_i, row["item_count"].to_i ] }
        dated_historical_records.each { |record| counts[quarter_of(record.pay_date)] = counts.fetch(quarter_of(record.pay_date), 0) + 1 }
        counts
      end
    end

    def quarter_of(date)
      ((date.month - 1) / 3) + 1
    end

    def native_quarter_rows
      @native_quarter_rows ||= PayrollItem
        .joins(:pay_period)
        .where(company_id: company.id)
        .financially_reportable.reportable
        .where.not(employment_type: "contractor")
        .where(pay_periods: { id: PayPeriod.reportable_committed.where(company_id: company.id, pay_date: year_range).select(:id) })
        .group(Arel.sql("EXTRACT(QUARTER FROM pay_periods.pay_date)"))
        .select(
          Arel.sql("EXTRACT(QUARTER FROM pay_periods.pay_date)::integer AS quarter"),
          Arel.sql("COUNT(*) AS item_count"),
          Arel.sql("SUM(COALESCE(social_security_taxable_wages, GREATEST(gross_pay - reported_tips, 0))) AS social_security_wages"),
          Arel.sql("SUM(COALESCE(social_security_taxable_tips, reported_tips)) AS social_security_tips"),
          Arel.sql("SUM(COALESCE(medicare_taxable_wages, gross_pay)) AS medicare_wages"),
          Arel.sql("SUM(social_security_tax) AS social_security_tax"),
          Arel.sql("SUM(medicare_tax) AS medicare_tax"),
          Arel.sql("SUM(withholding_tax + COALESCE(additional_withholding, 0)) AS guam_income_tax")
        )
        .map(&:attributes)
    end

    def historical_record_values(record)
      {
        "social_security_wages" => record.social_security_taxable_wages.to_d,
        "social_security_tips" => record.social_security_taxable_tips.to_d,
        "medicare_wages" => record.medicare_taxable_wages.to_d,
        "social_security_tax" => record.social_security_tax.to_d,
        "medicare_tax" => record.medicare_tax.to_d,
        "guam_income_tax" => record.total_income_tax_withheld.to_d
      }
    end

    def historical_source
      @historical_source ||= HistoricalPayrollFilingSource.new(company)
    end

    def locked_history?
      return @locked_history if defined?(@locked_history)

      @locked_history = company.historical_import_batches
        .joins(:historical_paychecks)
        .where(status: "locked", historical_paychecks: { pay_date: year_range })
        .exists?
    end

    def all_historical_records
      @all_historical_records ||= locked_history? ? historical_source.records(range: year_range, include_opening_summaries: true) : []
    end

    def dated_historical_records
      @dated_historical_records ||= locked_history? ? historical_source.records(range: year_range) : []
    end

    def opening_balance_values
      dated_keys = dated_historical_records.to_set(&:key)
      records = all_historical_records.reject { |record| dated_keys.include?(record.key) }
      totals = Hash.new(0.to_d)
      records.each { |record| historical_record_values(record).each { |key, value| totals[key] += value } }
      {
        present: records.any?,
        first_pay_date: records.map(&:period_start).compact.min,
        last_pay_date: records.map(&:pay_date).compact.max,
        totals: totals
      }
    end

    def quarter_payload(quarter)
      responsibility = quarterly_responsibilities[quarter]
      {
        quarter: quarter,
        label: "Q#{quarter}",
        record_count: record_counts.fetch(quarter, 0),
        form_941_filed_by: responsibility&.responsible_party
      }
    end

    def quarterly_responsibilities
      @quarterly_responsibilities ||= company.payroll_filing_responsibilities
        .where(tax_year: year, filing_type: "form_941").where.not(quarter: nil)
        .index_by(&:quarter)
    end

    def line_payload(line, quarter_values, record_values, opening)
      key = line[:key]
      w2_total = decimal(w2_report.dig(:totals, line[:w2_total]))
      opening_total = opening[:totals][key].round(2)
      quarters = QUARTERS.map do |quarter|
        filed = quarter_values[quarter][key].round(2)
        records = record_values[quarter][key].round(2)
        { quarter: quarter, amount: filed.to_f, payroll_records: records.to_f, difference: (filed - records).round(2).to_f }
      end
      quarterly_total = quarters.sum(0.to_d) { |quarter| decimal(quarter[:amount]) }.round(2)
      records_total = quarters.sum(0.to_d) { |quarter| decimal(quarter[:payroll_records]) }.round(2)
      difference = (w2_total - quarterly_total - opening_total).round(2)
      w2_side_difference = (w2_total - records_total - opening_total).round(2)
      mismatch = difference.abs > TOLERANCE
      look_at = mismatch ? look_at_for(quarters, w2_side_difference, line) : []

      {
        key: key,
        label: line[:label],
        w2_box: line[:w2_box],
        source: line[:source],
        source_label: line[:source_label],
        w2_total: w2_total.to_f,
        quarters: quarters,
        quarterly_total: quarterly_total.to_f,
        opening_balances: opening_total.to_f,
        difference: difference.to_f,
        status: mismatch ? "mismatch" : "match",
        look_at: look_at,
        message: mismatch ? mismatch_message(line, difference, look_at) : nil
      }
    end

    def look_at_for(quarters, w2_side_difference, line)
      source = line[:source] == "w1" ? "W-1" : "941"
      targets = quarters.filter_map do |quarter|
        next unless decimal(quarter[:difference]).abs > TOLERANCE

        {
          kind: "quarter",
          quarter: quarter[:quarter],
          label: "Q#{quarter[:quarter]} #{source}",
          detail: "The Q#{quarter[:quarter]} #{source} shows #{money(quarter[:amount])}, but Q#{quarter[:quarter]} payroll records total #{money(quarter[:payroll_records])}."
        }
      end
      if w2_side_difference.abs > TOLERANCE
        targets << {
          kind: "w2_report",
          label: "W-2GU report",
          detail: "The W-2GU #{line[:w2_box]} total differs from the year's payroll records and opening balances by #{money(w2_side_difference)}. Check the employee rows on the W-2GU report."
        }
      end
      targets.presence || [ { kind: "w2_report", label: "W-2GU report and quarterly returns", detail: "Compare the W-2GU employee rows with each quarter's return." } ]
    end

    def mismatch_message(line, difference, look_at)
      returns = line[:source] == "w1" ? "W-1s" : "941s"
      direction = difference.positive? ? "more" : "less"
      places = look_at.map { |target| target[:label] }.to_sentence
      "W-2 #{line[:w2_box]} (#{line[:label]}) is #{money(difference.abs)} #{direction} than the #{returns} and opening balances. Look at the #{places}."
    end

    def unavailable(message)
      self.class.unavailable(message)
    end

    def decimal(value)
      BigDecimal(value.to_s.presence || "0")
    end

    def money(value)
      amount = decimal(value)
      formatted = ActiveSupport::NumberHelper.number_to_currency(amount.abs, precision: 2)
      amount.negative? ? "-#{formatted}" : formatted
    end
  end
end
