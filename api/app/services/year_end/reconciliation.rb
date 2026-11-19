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
  #
  # The Social Security wage base is applied the same way on both sides:
  # opening balances use the capped YTD bridge allocation the W-2GU uses.
  # Wage-base differences are attributed employee by employee, never pooled:
  # a quarter's 941 may be lower than its records only by each employee's own
  # cap, and Box 3/Box 7 may split wages and tips differently from lines 5a
  # and 5b only where the same employee's W-2 and 941 totals agree. Each 941's
  # own withholding reconciliation is carried through: an unexplained
  # employee-tax difference blocks, and a recorded-liability residual needs a
  # reviewer's acknowledgement.
  class Reconciliation
    TOLERANCE = BigDecimal("0.01")
    QUARTERS = (1..4).freeze
    SS_KEYS = %w[social_security_wages social_security_tips].freeze
    STORED_SS_BASES = "social_security_taxable_wages IS NOT NULL AND social_security_taxable_tips IS NOT NULL"

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
        form_941_reviews: [],
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
      lines = LINES.map { |line| line_values(line, quarter_values, record_values, opening) }
      explain_capped_quarters(lines)
      lines.each { |line| line[:status] = line[:difference].abs > TOLERANCE || line[:quarter_mismatches].any? ? "mismatch" : "match" }
      explain_wage_base_split(lines, opening)
      lines.each { |line| describe_line(line) }
      mismatched = lines.select { |line| line[:status] == "mismatch" }
      reviews = form_941_reviews
      unexplained = reviews.select { |review| review[:status] == "unexplained" }

      {
        status: mismatched.empty? && unexplained.empty? ? "match" : "mismatch",
        tolerance: TOLERANCE.to_f,
        quarters: QUARTERS.map { |quarter| quarter_payload(quarter) },
        opening_balances: {
          present: opening[:present],
          first_pay_date: opening[:first_pay_date]&.iso8601,
          last_pay_date: opening[:last_pay_date]&.iso8601
        },
        lines: lines.map { |line| line_payload(line) },
        form_941_reviews: reviews,
        blockers: mismatched.map { |line| { code: "RECONCILIATION_MISMATCH", line: line[:key], message: line[:message] } } +
          unexplained.map { |review| { code: "FORM_941_WITHHOLDING_MISMATCH", line: nil, quarter: review[:quarter], message: review[:message] } }
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
      aggregator = Form941GuAggregator.new(company, year, quarter)
      report = aggregator.generate
      filed_by_employee[quarter] = aggregator.ss_taxable_by_employee.transform_values do |values|
        { "social_security_wages" => values[:wages], "social_security_tips" => values[:tips] }
      end
      lines = report.fetch(:lines)
      quarter_withholding[quarter] = report.fetch(:withholding_reconciliation).merge(line6_total_taxes: lines[:line6_total_taxes_before_adj])
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

    # Each employee's 941 lines 5a and 5b, by quarter.
    def filed_by_employee
      @filed_by_employee ||= {}
    end

    # Committed Cornerstone payroll, plus dated imported records, using the
    # stored bases the W-2GU itself sums.
    def payroll_record_values
      totals = QUARTERS.index_with { Hash.new(0.to_d) }
      employee_quarter_records.each do |(_employee_id, quarter), values|
        LINES.each { |line| totals[quarter][line[:key]] += values[line[:key]] }
      end
      totals
    end

    def record_counts
      @record_counts ||= employee_quarter_records.each_with_object(Hash.new(0)) do |((_employee_id, quarter), values), counts|
        counts[quarter] += values[:count]
      end
    end

    # Each employee's payroll records per quarter, from one grouped query plus
    # dated imported records. `basis` is what the 941 allocates before it
    # applies the wage base: the stored bases when a paycheck has both,
    # otherwise gross less tips and the tips (its legacy fallback). Imported
    # paychecks are allocated from their stored amounts.
    def employee_quarter_records
      @employee_quarter_records ||= begin
        records = Hash.new do |hash, key|
          hash[key] = LINES.to_h { |line| [ line[:key], 0.to_d ] }.merge(count: 0, capped_by_941: false, basis: SS_KEYS.index_with { 0.to_d })
        end
        native_employee_quarter_rows.each do |row|
          values = records[[ row["employee_id"], row["quarter"].to_i ]]
          LINES.each { |line| values[line[:key]] += decimal(row[line[:key]]) }
          SS_KEYS.each { |key| values[:basis][key] += decimal(row["#{key}_basis"]) }
          values[:count] += row["item_count"].to_i
          values[:capped_by_941] ||= row["legacy_ss_count"].to_i.positive?
        end
        dated_historical_records.each do |record|
          values = records[[ record.employee_id, quarter_of(record.pay_date) ]]
          amounts = historical_record_values(record)
          amounts.each { |key, value| values[key] += value }
          SS_KEYS.each { |key| values[:basis][key] += amounts[key] }
          values[:count] += 1
          values[:capped_by_941] = true
        end
        records.default_proc = nil
        records
      end
    end

    def quarter_of(date)
      ((date.month - 1) / 3) + 1
    end

    def native_employee_quarter_rows
      @native_employee_quarter_rows ||= W2PayrollItems.scope(company.id, year)
        .group(Arel.sql("EXTRACT(QUARTER FROM pay_periods.pay_date)"), "payroll_items.employee_id")
        .select(
          Arel.sql("EXTRACT(QUARTER FROM pay_periods.pay_date)::integer AS quarter"),
          Arel.sql("payroll_items.employee_id AS employee_id"),
          Arel.sql("COUNT(*) AS item_count"),
          Arel.sql("COUNT(*) FILTER (WHERE NOT (#{STORED_SS_BASES})) AS legacy_ss_count"),
          Arel.sql("SUM(CASE WHEN #{STORED_SS_BASES} THEN social_security_taxable_wages ELSE GREATEST(gross_pay - reported_tips, 0) END) AS social_security_wages_basis"),
          Arel.sql("SUM(CASE WHEN #{STORED_SS_BASES} THEN social_security_taxable_tips ELSE reported_tips END) AS social_security_tips_basis"),
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

    # Opening summaries per employee, as the W-2GU counts them. An employee
    # whose only imported history is opening summaries takes the YTD bridge
    # amounts outright, since that is exactly what the W-2GU adds. Otherwise
    # the ledger amounts are capped at the wage base the way the bridge caps
    # them (tips first, then wages) and never above the employee's bridge.
    def opening_balance_values
      dated_keys = dated_historical_records.to_set(&:key)
      dated_employee_ids = dated_historical_records.to_set(&:employee_id)
      records = all_historical_records.reject { |record| dated_keys.include?(record.key) }
      totals = Hash.new(0.to_d)
      by_employee = records.group_by(&:employee_id).to_h do |employee_id, employee_records|
        bridge = bridge_values[employee_id]
        values = if bridge && !dated_employee_ids.include?(employee_id)
          bridge
        else
          capped_social_security(sum_values(employee_records), bridge)
        end
        values.each { |key, value| totals[key] += value }
        [ employee_id, values ]
      end
      {
        present: records.any?,
        first_pay_date: records.map(&:period_start).compact.min,
        last_pay_date: records.map(&:pay_date).compact.max,
        totals: totals,
        by_employee: by_employee
      }
    end

    def sum_values(records)
      records.each_with_object(Hash.new(0.to_d)) do |record, values|
        historical_record_values(record).each { |key, value| values[key] += value }
      end
    end

    def capped_social_security(values, bridge)
      wages = values["social_security_wages"]
      tips = values["social_security_tips"]
      limit = [ ss_wage_base, bridge && (bridge["social_security_wages"] + bridge["social_security_tips"]) ].compact.min
      return values if wages.negative? || tips.negative? || wages + tips <= limit

      room = [ limit, 0.to_d ].max
      capped_tips = [ tips, room ].min
      values.merge("social_security_wages" => room - capped_tips, "social_security_tips" => capped_tips)
    end

    # Each employee's YTD bridge amounts, summed over locked imports.
    def bridge_values
      @bridge_values ||= (locked_history? ? historical_source.annual_balances(year) : []).group_by(&:employee_id).transform_values do |balances|
        {
          "social_security_wages" => balances.sum(0.to_d) { |balance| balance.social_security_taxable_wages.to_d },
          "social_security_tips" => balances.sum(0.to_d) { |balance| balance.social_security_taxable_tips.to_d },
          "medicare_wages" => balances.sum(0.to_d) { |balance| balance.medicare_taxable_wages.to_d },
          "social_security_tax" => balances.sum(0.to_d) { |balance| balance.social_security_tax.to_d },
          "medicare_tax" => balances.sum(0.to_d) { |balance| balance.medicare_tax.to_d },
          "guam_income_tax" => balances.sum(0.to_d) { |balance| balance.federal_income_tax.to_d + balance.additional_withholding.to_d }
        }
      end
    end

    def ss_wage_base
      @ss_wage_base ||= AnnualTaxConfig.for_year(year)&.ss_wage_base&.to_d || W2GuAggregator::SS_WAGE_BASE_BY_YEAR.fetch(year).to_d
    rescue KeyError
      raise ArgumentError, "SS wage base not configured for #{year}"
    end

    # The W-2GU applies the wage base to wages first for the whole year; the
    # 941s apply it paycheck by paycheck. For an employee who reaches the base
    # with tips (or has legacy tipped rows), the two splits differ while that
    # employee's Social Security total is the same. The split is explained
    # only when every employee whose Box 3 and Box 7 differ from their own 941
    # totals is such an employee, their Box 3 + Box 7 equals their lines
    # 5a + 5b, and those shifts add up to the whole difference. It is an
    # annual difference only: a quarter whose 941 differs from its own
    # payroll records is never explained by it.
    def explain_wage_base_split(lines, opening)
      wages = lines.find { |line| line[:key] == "social_security_wages" }
      tips = lines.find { |line| line[:key] == "social_security_tips" }
      return unless wages[:status] == "mismatch" && tips[:status] == "mismatch"
      return if [ wages, tips ].any? { |line| line[:quarter_mismatches].any? }

      shift = wages[:difference]
      return if (shift + tips[:difference]).abs > TOLERANCE

      employee_shifts = wage_tip_shifts_by_employee(opening)
      return if employee_shifts.nil? || (employee_shifts.values.sum(0.to_d) - shift).abs > TOLERANCE

      note = "Box 3 and Box 7 split Social Security wages and tips differently from lines 5a and 5b by #{money(shift.abs)}, " \
             "because the W-2 applies the wage base to wages first. Box 3 + Box 7 equals lines 5a + 5b."
      [ wages, tips ].each do |line|
        line.merge!(status: "explained", note: note)
      end
    end

    # Each employee's Box 3 shift against their own 941 wages and opening
    # balances, or nil when any employee's difference is not a wage-first
    # split: their Social Security total differs, the W-2 moves wages into
    # tips, or they are neither at the wage base nor on paychecks the 941
    # caps itself.
    def wage_tip_shifts_by_employee(opening)
      rows = Array(w2_report[:employees])
      return nil if rows.any? { |row| row[:employee_id].nil? }

      rows_by_employee = rows.index_by { |row| row[:employee_id] }
      filed = annual_filed_by_employee
      (rows_by_employee.keys | filed.keys | opening[:by_employee].keys).each_with_object({}) do |employee_id, shifts|
        row = rows_by_employee.fetch(employee_id, {})
        box3 = decimal(row[:box3_social_security_wages])
        box7 = decimal(row[:box7_social_security_tips])
        reported = SS_KEYS.to_h do |key|
          [ key, filed.dig(employee_id, key).to_d + opening[:by_employee].dig(employee_id, key).to_d ]
        end
        shift_wages = box3 - reported["social_security_wages"]
        shift_tips = box7 - reported["social_security_tips"]
        next if shift_wages.abs <= TOLERANCE && shift_tips.abs <= TOLERANCE

        at_base = box3 + box7 >= ss_wage_base - TOLERANCE
        capped_by_941 = QUARTERS.any? { |quarter| employee_quarter_records.dig([ employee_id, quarter ], :capped_by_941) }
        return nil unless (shift_wages + shift_tips).abs <= TOLERANCE && shift_wages.positive? && (at_base || capped_by_941)

        shifts[employee_id] = shift_wages
      end
    end

    def annual_filed_by_employee
      filed_by_employee.values.each_with_object({}) do |employees, totals|
        employees.each do |employee_id, values|
          employee_totals = totals[employee_id] ||= SS_KEYS.index_with { 0.to_d }
          SS_KEYS.each { |key| employee_totals[key] += values[key] }
        end
      end
    end

    # Legacy paychecks (no stored Social Security bases) and dated imported
    # paychecks are capped at the wage base paycheck by paycheck on the 941,
    # but their payroll records here are not capped. A quarter's 941 may be
    # lower than its records only by each employee's own cap: an employee
    # whose 941 amount differs from their records is explained only when the
    # 941 started from exactly those records, so only the cap lowered it. A
    # quarter whose 941 is higher, or differs for any other reason, still
    # blocks.
    def explain_capped_quarters(lines)
      lines.select { |line| line[:key].in?(SS_KEYS) }.each do |line|
        capped, unexplained = line[:quarter_mismatches].partition { |quarter| capped_quarter?(line[:key], quarter) }
        line[:capped_quarters] = capped
        line[:quarter_mismatches] = unexplained
      end
    end

    def capped_quarter?(key, quarter)
      return false unless quarter[:difference].negative?

      filed = filed_by_employee.fetch(quarter[:quarter], {})
      employee_ids = employee_quarter_records.keys.filter_map { |employee_id, record_quarter| employee_id if record_quarter == quarter[:quarter] }
      reductions = (employee_ids | filed.keys).sum(0.to_d) do |employee_id|
        records = employee_quarter_records[[ employee_id, quarter[:quarter] ]]
        return false if records.nil?

        difference = filed.dig(employee_id, key).to_d - records[key]
        next 0.to_d if difference.abs <= TOLERANCE
        return false if difference.positive? || (records[key] - records[:basis][key]).abs > TOLERANCE

        difference
      end
      (quarter[:difference] - reductions).abs <= TOLERANCE
    end

    def quarter_withholding
      @quarter_withholding ||= {}
    end

    # Each 941's own check of recorded employee Social Security and Medicare
    # withholding against the employee share of the quarter's wage bases.
    def form_941_reviews
      QUARTERS.filter_map do |quarter|
        review = quarter_withholding[quarter]
        next unless review && review[:requires_review]

        employee_difference = decimal(review[:employee_difference])
        unexplained = review[:line7_suggestion].nil? && employee_difference.nonzero?
        {
          quarter: quarter,
          status: unexplained ? "unexplained" : "residual",
          employee_difference: employee_difference.to_f,
          expected_employee_total: decimal(review[:expected_employee_total]).to_f,
          recorded_employee_total: decimal(review[:recorded_employee_total]).to_f,
          recorded_employer_total: decimal(review[:recorded_employer_total]).to_f,
          recorded_total_liability: decimal(review[:recorded_total_liability]).to_f,
          line6_total_taxes: decimal(review[:line6_total_taxes]).to_f,
          recorded_liability_residual: decimal(review[:recorded_liability_residual]).to_f,
          message: form_941_review_message(quarter, unexplained, employee_difference, decimal(review[:recorded_liability_residual]))
        }
      end
    end

    def form_941_review_message(quarter, unexplained, employee_difference, residual)
      if unexplained
        direction = employee_difference.negative? ? "less" : "more"
        "The Q#{quarter} 941: employee Social Security and Medicare withheld is #{money(employee_difference.abs)} #{direction} than " \
          "the employee share of the quarter's wages. Correct the Q#{quarter} payroll (or file a 941-X) before marking ready."
      else
        "The Q#{quarter} 941: recorded tax liability differs from line 6 by #{money(residual)} after the line 7 rounding adjustment. " \
          "Confirm the employer amounts for Q#{quarter}."
      end
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

    # One line's amounts, kept as BigDecimal until line_payload. A line
    # blocks when the W-2 total differs from the quarters and opening balances,
    # or when any quarter's return differs from that quarter's payroll records,
    # even if those quarter differences cancel over the year.
    def line_values(line, quarter_values, record_values, opening)
      key = line[:key]
      w2_total = decimal(w2_report.dig(:totals, line[:w2_total])).round(2)
      opening_total = opening[:totals][key].round(2)
      quarters = QUARTERS.map do |quarter|
        filed = quarter_values[quarter][key].round(2)
        records = record_values[quarter][key].round(2)
        { quarter: quarter, amount: filed, payroll_records: records, difference: filed - records }
      end
      quarterly_total = quarters.sum(0.to_d) { |quarter| quarter[:amount] }
      records_total = quarters.sum(0.to_d) { |quarter| quarter[:payroll_records] }
      difference = w2_total - quarterly_total - opening_total
      w2_side_difference = w2_total - records_total - opening_total
      {
        key: key,
        label: line[:label],
        w2_box: line[:w2_box],
        source: line[:source],
        source_label: line[:source_label],
        w2_total: w2_total,
        quarters: quarters,
        quarterly_total: quarterly_total,
        opening_balances: opening_total,
        difference: difference,
        w2_side_difference: w2_side_difference,
        quarter_mismatches: quarters.select { |quarter| quarter[:difference].abs > TOLERANCE },
        capped_quarters: [],
        status: nil,
        look_at: [],
        message: nil,
        note: nil
      }
    end

    def describe_line(line)
      if line[:status] == "mismatch"
        line[:look_at] = look_at_for(line[:quarter_mismatches], line[:w2_side_difference], line)
        line[:message] = mismatch_message(line, line[:difference], line[:quarter_mismatches], line[:look_at])
      elsif line[:capped_quarters].any?
        quarters = line[:capped_quarters].map { |quarter| "Q#{quarter[:quarter]}" }.to_sentence
        capped = "The #{quarters} 941#{'s' if line[:capped_quarters].length > 1} cap#{'s' if line[:capped_quarters].length == 1} legacy paychecks " \
                 "at the Social Security wage base, so #{line[:capped_quarters].length > 1 ? 'they are' : 'it is'} lower than the uncapped payroll records."
        line.merge!(status: "explained", note: [ line[:note], capped ].compact.join(" "))
      end
    end

    def line_payload(line)
      line.except(:quarter_mismatches, :capped_quarters, :w2_side_difference).merge(
        w2_total: line[:w2_total].to_f,
        quarters: line[:quarters].map { |quarter| quarter.merge(amount: quarter[:amount].to_f, payroll_records: quarter[:payroll_records].to_f, difference: quarter[:difference].to_f) },
        quarterly_total: line[:quarterly_total].to_f,
        opening_balances: line[:opening_balances].to_f,
        difference: line[:difference].to_f
      )
    end

    def look_at_for(quarter_mismatches, w2_side_difference, line)
      source = line[:source] == "w1" ? "W-1" : "941"
      targets = quarter_mismatches.map do |quarter|
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

    def mismatch_message(line, difference, quarter_mismatches, look_at)
      returns = line[:source] == "w1" ? "W-1s" : "941s"
      places = look_at.map { |target| target[:label] }.to_sentence
      if difference.abs > TOLERANCE
        direction = difference.positive? ? "more" : "less"
        return "W-2 #{line[:w2_box]} (#{line[:label]}) is #{money(difference.abs)} #{direction} than the #{returns} and opening balances. Look at the #{places}."
      end

      source = line[:source] == "w1" ? "W-1" : "941"
      quarters = quarter_mismatches.map do |quarter|
        "the Q#{quarter[:quarter]} #{source} is #{money(quarter[:difference].abs)} #{quarter[:difference].positive? ? 'more' : 'less'} than Q#{quarter[:quarter]} payroll records"
      end
      "W-2 #{line[:w2_box]} (#{line[:label]}) matches the #{returns} in total, but #{quarters.to_sentence}. " \
        "Correct the quarter#{'s' if quarter_mismatches.length > 1} the wages were reported in. Look at the #{places}."
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
