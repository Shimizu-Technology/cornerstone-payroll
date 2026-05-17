# frozen_string_literal: true

module QuarterlyComplianceOfficialForms
  MONTHS_BY_QUARTER = QuarterlyCompliancePacketBuilder::MONTHS_BY_QUARTER

  class BaseForm < OfficialPdfOverlay
    attr_reader :report, :fields

    def initialize(report:, template_path:, page_sizes:, fields: {})
      @report = report.deep_symbolize_keys
      @fields = fields.to_h.deep_symbolize_keys
      super(template_path: template_path, page_sizes: page_sizes)
    end

    private

    def meta
      report.fetch(:meta)
    end

    def company_name
      fields[:company_name].presence || meta[:company_name].to_s
    end

    def ein
      fields[:ein].presence || meta[:ein].to_s
    end

    def year
      meta[:year].to_i
    end

    def quarter
      meta[:quarter].to_i
    end

    def quarter_end
      Date.parse(meta[:quarter_end].to_s)
    end

    def company_address_lines
      info = report.dig(:federal_941, :report, :employer_info) || {}
      [ info[:address].presence ].compact_blank
    end

    def company_address
      fields[:company_address].presence || company_address_lines.first.to_s
    end

    def company_address_line1
      fields[:company_address_line1].presence || meta[:company_address_line1].to_s.presence || company_address
    end

    def company_address_line2
      fields[:company_address_line2].presence || meta[:company_address_line2].to_s
    end

    def company_city
      fields[:company_city].presence || meta[:company_city].to_s
    end

    def company_state
      fields[:company_state].presence || meta[:company_state].to_s
    end

    def company_zip
      fields[:company_zip].presence || meta[:company_zip].to_s
    end

    def company_city_state
      [ company_city, company_state ].compact_blank.join(", ")
    end

    def line_value(key)
      fields.dig(:lines, key) || fields[key] || report.dig(:federal_941, :report, :lines, key)
    end

    def amount_fields(pdf, dollar_rect, cent_rect, value, size: 8.5)
      dollars, cents = money_parts(value)
      draw_text_box(pdf, dollar_rect, dollars, size: size, align: :right)
      draw_text_box(pdf, cent_rect, cents, size: size, align: :center)
    end
  end

  class Form941 < BaseForm
    TEMPLATE_PATH = Rails.root.join("lib/assets/irs_form_941_2026.pdf")
    PAGE_SIZE = [ 611.976, 791.968 ].freeze

    HEADER = {
      ein_prefix: [ 153.281, 707.969, 197.504, 725.969 ],
      ein_suffix: [ 215.83, 707.969, 387.944, 725.969 ],
      name: [ 136.8, 683.968, 388.8, 701.968 ],
      trade_name: [ 115.2, 659.967, 388.8, 677.967 ],
      address: [ 79.2, 635.97, 388.8, 653.969 ],
      city: [ 79.2, 605.968, 266.4, 623.967 ],
      state: [ 273.6, 605.968, 309.6, 623.967 ],
      zip: [ 316.8, 605.968, 388.8, 623.967 ],
      quarters: [
        [ 424.8, 684.968, 434.8, 694.968 ],
        [ 424.8, 668.969, 434.8, 678.969 ],
        [ 424.8, 652.968, 434.8, 662.968 ],
        [ 424.8, 636.969, 434.8, 646.969 ]
      ]
    }.freeze

    LINE_RECTS = {
      line1_employee_count: [ [ 446.4, 483.966, 576.0, 497.967 ], nil ],
      line5a_ss_wages: [ [ 216.0, 389.966, 280.8, 403.967 ], [ 288.0, 389.966, 308.85, 403.967 ] ],
      line5a_ss_combined_tax: [ [ 352.8, 389.966, 417.6, 403.967 ], [ 424.8, 389.966, 445.65, 403.967 ] ],
      line5b_ss_tips: [ [ 216.0, 369.968, 280.8, 383.969 ], [ 288.0, 369.968, 308.85, 383.969 ] ],
      line5b_ss_tips_combined_tax: [ [ 352.8, 369.968, 417.6, 383.969 ], [ 424.8, 369.968, 445.65, 383.969 ] ],
      line5c_medicare_wages: [ [ 216.0, 349.967, 280.8, 363.968 ], [ 288.0, 349.967, 308.85, 363.968 ] ],
      line5c_medicare_combined_tax: [ [ 352.8, 349.967, 417.6, 363.968 ], [ 424.8, 349.967, 445.65, 363.968 ] ],
      line5d_add_medicare_wages: [ [ 216.0, 323.964, 280.8, 337.965 ], [ 288.0, 323.964, 308.85, 337.965 ] ],
      line5d_add_medicare_tax: [ [ 352.8, 323.964, 417.6, 337.965 ], [ 424.8, 323.964, 445.65, 337.965 ] ],
      line5e_total_ss_medicare: [ [ 446.4, 301.968, 547.2, 315.969 ], [ 554.4, 301.968, 575.25, 315.969 ] ],
      line6_total_taxes_before_adj: [ [ 446.4, 282.967, 547.2, 296.968 ], [ 554.4, 282.967, 575.25, 296.968 ] ],
      line7_adj_fractions_cents: [ [ 446.4, 263.966, 547.2, 277.967 ], [ 554.4, 263.966, 575.25, 277.967 ] ],
      line10_total_taxes_after_adj: [ [ 446.4, 206.967, 547.2, 220.968 ], [ 554.4, 206.967, 575.25, 220.968 ] ],
      line12_total_after_credits: [ [ 446.4, 168.966, 547.2, 182.967 ], [ 554.4, 168.966, 575.25, 182.967 ] ]
    }.freeze

    PAGE2 = {
      name: [ 36.0, 719.968, 286.999, 733.968 ],
      ein_prefix: [ 410.4, 719.968, 432.0, 733.968 ],
      ein_suffix: [ 438.0, 719.968, 487.6, 733.968 ],
      under_2500: [ 109.2, 674.97, 119.2, 684.97 ],
      monthly: [ 109.2, 625.971, 119.2, 635.971 ],
      semiweekly: [ 109.2, 510.969, 119.2, 520.969 ],
      month1: [ [ 230.4, 591.966, 331.2, 605.967 ], [ 338.4, 591.966, 359.25, 605.967 ] ],
      month2: [ [ 230.4, 569.966, 331.2, 583.967 ], [ 338.4, 569.966, 359.25, 583.967 ] ],
      month3: [ [ 230.4, 548.967, 331.2, 562.968 ], [ 338.4, 548.967, 359.25, 562.968 ] ],
      quarter_total: [ [ 230.4, 526.968, 331.2, 540.969 ], [ 338.4, 526.968, 359.25, 540.969 ] ]
    }.freeze

    def initialize(report:, fields: {})
      super(report: report, fields: fields, template_path: TEMPLATE_PATH, page_sizes: [ PAGE_SIZE, PAGE_SIZE, PAGE_SIZE ])
    end

    private

    def draw_page(pdf, page_number)
      case page_number
      when 1 then draw_page_one(pdf)
      when 2 then draw_page_two(pdf)
      end
    end

    def draw_page_one(pdf)
      draw_ein_digits(pdf, split_rect_horizontally(HEADER[:ein_prefix], 2) + split_rect_horizontally(HEADER[:ein_suffix], 7))
      draw_text_box(pdf, HEADER[:name], company_name, size: 9)
      draw_text_box(pdf, HEADER[:address], [ company_address_line1, company_address_line2 ].compact_blank.join(" "), size: 8)
      draw_text_box(pdf, HEADER[:city], company_city, size: 8)
      draw_text_box(pdf, HEADER[:state], company_state, size: 8, align: :center)
      draw_text_box(pdf, HEADER[:zip], company_zip, size: 8, align: :center)
      draw_checkbox(pdf, HEADER[:quarters][quarter - 1], true)

      lines = report.dig(:federal_941, :report, :lines) || {}
      LINE_RECTS.each do |key, rects|
        value = line_value(key)
        next if value.nil?

        if rects.last.nil?
          draw_text_box(pdf, rects.first, value, size: 8.5, align: :right)
        else
          amount_fields(pdf, rects.first, rects.last, value)
        end
      end
    end

    def draw_page_two(pdf)
      draw_text_box(pdf, PAGE2[:name], company_name, size: 8.5)
      draw_ein_digits(pdf, split_rect_horizontally(PAGE2[:ein_prefix], 2) + split_rect_horizontally(PAGE2[:ein_suffix], 7))

      line12 = line_value(:line12_total_after_credits).to_f
      schedule = report.dig(:federal_941, :deposit_schedule, :suggested_schedule)
      schedule_b_required = report.dig(:federal_941, :deposit_schedule, :schedule_b_required)
      draw_checkbox(pdf, PAGE2[:under_2500], line12 < 2500)
      draw_checkbox(pdf, PAGE2[:monthly], !schedule_b_required && schedule == "monthly" && line12 >= 2500)
      draw_checkbox(pdf, PAGE2[:semiweekly], schedule_b_required)

      return if schedule_b_required || line12 < 2500

      monthly = Array(report.dig(:federal_941, :report, :monthly_liability))
      monthly.first(3).each_with_index do |row, index|
        amount_fields(pdf, PAGE2.fetch(:"month#{index + 1}").first, PAGE2.fetch(:"month#{index + 1}").last, row[:total_liability])
      end
      amount_fields(pdf, PAGE2[:quarter_total].first, PAGE2[:quarter_total].last, line12)
    end

    def draw_ein_digits(pdf, rects)
      ein_digits(ein).each_with_index do |digit, index|
        draw_text_box(pdf, rects[index], digit, size: 7, align: :center, min_font_size: 5)
      end
    end
  end

  class ScheduleB < BaseForm
    TEMPLATE_PATH = Rails.root.join("lib/assets/irs_form_941_schedule_b.pdf")
    PAGE_SIZE = [ 610.976, 791.968 ].freeze

    EIN_RECTS = [
      [ 145.919, 683.968, 165.359, 701.968 ], [ 171.388, 683.968, 190.828, 701.968 ],
      [ 209.769, 683.968, 229.209, 701.968 ], [ 235.168, 683.968, 254.608, 701.968 ],
      [ 260.478, 683.968, 279.918, 701.968 ], [ 285.877, 683.968, 305.317, 701.968 ],
      [ 311.267, 683.968, 330.707, 701.968 ], [ 336.668, 683.968, 356.108, 701.968 ],
      [ 362.157, 683.968, 381.597, 701.968 ]
    ].freeze
    NAME_RECT = [ 130.6, 659.967, 380.6, 677.967 ].freeze
    YEAR_RECTS = [
      [ 145.919, 635.969, 165.359, 653.969 ], [ 171.388, 635.969, 190.828, 653.969 ],
      [ 196.747, 635.969, 216.187, 653.969 ], [ 222.239, 635.969, 241.679, 653.969 ]
    ].freeze
    QUARTERS = [
      [ 420.8, 672.966, 430.8, 682.966 ], [ 420.8, 654.966, 430.8, 664.966 ],
      [ 420.8, 636.966, 430.8, 646.966 ], [ 420.8, 618.966, 430.8, 628.966 ]
    ].freeze
    MONTH_DAY_STARTS = {
      1 => 15,
      2 => 79,
      3 => 143
    }.freeze
    MONTH_TOTAL_RECTS = {
      1 => [ [ 453.6, 499.968, 545.2, 515.967 ], [ 555.152, 499.968, 574.0, 515.967 ] ],
      2 => [ [ 453.6, 343.969, 545.2, 359.968 ], [ 554.4, 343.969, 574.0, 359.968 ] ],
      3 => [ [ 453.6, 187.97, 545.2, 203.969 ], [ 554.4, 187.97, 574.0, 203.969 ] ]
    }.freeze
    QUARTER_TOTAL = [ [ 453.6, 49.968, 545.2, 65.967 ], [ 554.4, 49.968, 574.0, 65.967 ] ].freeze

    def initialize(report:, fields: {})
      super(report: report, fields: fields, template_path: TEMPLATE_PATH, page_sizes: [ PAGE_SIZE ])
    end

    private

    def draw_page(pdf, _page_number)
      ein_digits(ein).each_with_index { |digit, index| draw_text_box(pdf, EIN_RECTS[index], digit, size: 9, align: :center) }
      draw_text_box(pdf, NAME_RECT, company_name, size: 8.5)
      year.to_s.chars.each_with_index { |digit, index| draw_text_box(pdf, YEAR_RECTS[index], digit, size: 9, align: :center) }
      draw_checkbox(pdf, QUARTERS[quarter - 1], true)

      daily = federal_daily_liability
      monthly_totals = Hash.new(0.0)
      daily.each do |row|
        month_index = quarter_months.index(row[:month].to_i) + 1
        day = Date.parse(row[:pay_date].to_s).day
        monthly_totals[month_index] += row[:amount].to_f
        amount_fields(pdf, *day_rects(month_index, day), row[:amount], size: 7.5)
      end

      (1..3).each do |month_index|
        amount_fields(pdf, MONTH_TOTAL_RECTS[month_index].first, MONTH_TOTAL_RECTS[month_index].last, monthly_totals[month_index])
      end
      amount_fields(pdf, QUARTER_TOTAL.first, QUARTER_TOTAL.last, monthly_totals.values.sum)
    end

    def federal_daily_liability
      return editable_daily_liability if fields[:daily_liabilities].present?

      grouped = Array(report[:pay_periods])
        .select { |period| Date.parse(period[:pay_date].to_s).month.in?(quarter_months) }
        .group_by { |period| period[:pay_date] }

      grouped.map do |pay_date, periods|
        {
          pay_date: pay_date,
          month: Date.parse(pay_date.to_s).month,
          amount: periods.sum { |period| period[:federal_941_liability].to_f }
        }
      end.sort_by { |row| row[:pay_date] }
    end

    def editable_daily_liability
      Array(fields[:daily_liabilities]).map do |row|
        pay_date = row[:pay_date]
        parsed = Date.parse(pay_date.to_s)
        next unless parsed.month.in?(quarter_months)

        { pay_date: pay_date, month: parsed.month, amount: row[:amount].to_f }
      end.compact.sort_by { |row| row[:pay_date] }
    end

    def quarter_months
      MONTHS_BY_QUARTER.fetch(quarter)
    end

    def day_rects(month_index, day)
      field_number = MONTH_DAY_STARTS.fetch(month_index) + ((day - 1) * 2)
      dollar_rect = schedule_b_rect_for_field(field_number)
      cent_rect = schedule_b_rect_for_field(field_number + 1)
      [ dollar_rect, cent_rect ]
    end

    def schedule_b_rect_for_field(field_number)
      # The IRS Schedule B daily liability grid is regular: each day has a
      # dollars box and a cents box. Coordinates mirror the official field grid.
      month_index = case field_number
      when 15..78 then 1
      when 79..142 then 2
      else 3
      end
      start = MONTH_DAY_STARTS.fetch(month_index)
      offset = field_number - start
      day_index = offset / 2
      is_cent = offset.odd?
      day = day_index + 1
      group = (day - 1) / 8
      row = (day - 1) % 8
      x_pairs = [
        [ 50.4, 108.0, 115.2, 134.8 ],
        [ 151.2, 208.8, 216.0, 235.6 ],
        [ 252.0, 309.6, 316.8, 336.4 ],
        [ 352.8, 410.4, 417.6, 437.2 ]
      ]
      y_top_by_month = { 1 => 539.968, 2 => 383.969, 3 => 227.967 }
      top = y_top_by_month.fetch(month_index) - (row * 18.0)
      bottom = top - 15.001
      left, right = if is_cent
        [ x_pairs[group][2], x_pairs[group][3] ]
      else
        [ x_pairs[group][0], x_pairs[group][1] ]
      end
      [ left, bottom, right, top ]
    end
  end

  class W1 < BaseForm
    TEMPLATE_PATH = Rails.root.join("lib/assets/guam_w1_quarterly_return.pdf")
    PAGE_SIZE = [ 618.0, 774.0 ].freeze

    HEADER = {
      name: [ 148.592834, 670.40686, 314.529297, 692.906677 ],
      quarter_end: [ 324.372986, 671.813049, 483.747009, 692.437927 ],
      trade_name: [ 148.592834, 640.875793, 314.998047, 662.43811 ],
      ein: [ 323.904266, 647.438232, 483.278259, 661.96936 ],
      address: [ 147.1866, 617.907166, 314.060577, 633.844543 ],
      city_state_zip: [ 323.904266, 618.375916, 486.559509, 633.375793 ]
    }.freeze
    TOTALS = {
      line1: [ 481.40329, 226.503357, 554.996582, 236.347046 ],
      line3: [ 483.278259, 203.065994, 555.465332, 213.378433 ]
    }.freeze

    def initialize(report:, fields: {})
      super(report: report, fields: fields, template_path: TEMPLATE_PATH, page_sizes: [ PAGE_SIZE ])
    end

    private

    def draw_page(pdf, _page_number)
      draw_text_box(pdf, HEADER[:name], company_name, size: 8)
      draw_text_box(pdf, HEADER[:quarter_end], quarter_end.strftime("%m/%d/%Y"), size: 8, align: :center)
      draw_text_box(pdf, HEADER[:ein], ein, size: 8, align: :center)
      draw_text_box(pdf, HEADER[:address], [ company_address_line1, company_address_line2 ].compact_blank.join(" "), size: 7.5)
      draw_text_box(pdf, HEADER[:city_state_zip], [ company_city_state, company_zip ].compact_blank.join(" "), size: 7.5)

      daily = Array(fields[:daily_liabilities].presence || report.dig(:w1, :daily_liabilities))
      totals = Hash.new(0.0)
      daily.each do |row|
        month_index = quarter_months.index(row[:month].to_i) + 1
        day = Date.parse(row[:pay_date].to_s).day
        totals[month_index] += row[:amount].to_f
        draw_text_box(pdf, w1_day_rect(month_index, day), money_string(row[:amount]), size: 6.8, align: :right)
      end

      total = fields[:total_guam_withholding].presence || report.dig(:w1, :total_guam_withholding).to_f
      draw_text_box(pdf, TOTALS[:line1], money_string(total), size: 7, align: :right)
      draw_text_box(pdf, TOTALS[:line3], money_string(total), size: 7, align: :right)
    end

    def quarter_months
      MONTHS_BY_QUARTER.fetch(quarter)
    end

    def w1_day_rect(month_index, day)
      y_groups = {
        1 => [ 541.5, 529.3, 516.6, 503.5, 491.0, 478.0 ],
        2 => [ 438.8, 426.6, 413.5, 400.4, 388.0, 374.6 ],
        3 => [ 335.2, 323.0, 309.4, 297.2, 284.1, 269.1, 256.0, 243.8 ]
      }
      x_groups = [
        [ 75.0, 146.0 ],
        [ 157.0, 228.0 ],
        [ 239.0, 310.0 ],
        [ 320.0, 392.0 ],
        [ 402.0, 475.0 ],
        [ 484.0, 557.0 ]
      ]
      group = if day <= 25
        (day - 1) / 5
      else
        5
      end
      row = if day <= 25
        (day - 1) % 5
      else
        day - 26
      end
      top = y_groups.fetch(month_index).fetch(row)
      [ x_groups[group][0], top - 12, x_groups[group][1], top ]
    end
  end

  class Sw2 < BaseForm
    TEMPLATE_PATH = Rails.root.join("lib/assets/guam_sw2_quarterly_wage_report.pdf")
    PAGE_SIZE = [ 1008.0, 614.0 ].freeze
    EMPLOYEES_PER_PAGE = 11

    HEADER = {
      ein: [ 166.250946, 529.624512, 358.752045, 547.124634 ],
      quarter_end: [ 471.877716, 530.874512, 625.628601, 547.124573 ],
      name: [ 752.504272, 529.624512, 977.505615, 547.124634 ],
      address: [ 164.375946, 506.49939, 359.377045, 523.374512 ],
      city_state: [ 442.502533, 506.49939, 626.253601, 523.374512 ],
      phone: [ 753.754333, 505.24939, 976.255615, 523.999512 ],
      zip: [ 166.875961, 482.124237, 357.502045, 499.624359 ],
      employee_count: [ 215.001236, 459.624115, 343.751953, 477.124207 ],
      total_wages: [ 516.25293, 457.124115, 624.378601, 474.624207 ],
      total_withheld: [ 923.13031, 455.874084, 1001.880737, 473.999207 ],
      page_current: [ 781.254456, 588.374878, 812.504639, 607.749939 ],
      page_total: [ 831.879761, 588.999878, 873.130005, 607.749939 ]
    }.freeze

    def initialize(report:, fields: {})
      symbolized_report = report.deep_symbolize_keys
      symbolized_fields = fields.to_h.deep_symbolize_keys
      @employee_pages = Array(symbolized_fields[:employees].presence || symbolized_report.dig(:swica, :employees)).each_slice(EMPLOYEES_PER_PAGE).to_a
      @employee_pages = [ [] ] if @employee_pages.empty?
      super(report: symbolized_report, fields: symbolized_fields, template_path: TEMPLATE_PATH, page_sizes: @employee_pages.map { PAGE_SIZE })
    end

    def generate
      super(page_count: employee_pages.length)
    end

    private

    attr_reader :employee_pages

    def draw_page(pdf, page_number)
      draw_header(pdf, page_number)
      employee_pages[page_number - 1].each_with_index do |employee, index|
        draw_employee_row(pdf, employee, index)
      end
    end

    def draw_header(pdf, page_number)
      totals = swica_totals
      draw_text_box(pdf, HEADER[:ein], ein, size: 8)
      draw_text_box(pdf, HEADER[:quarter_end], quarter_end.strftime("%m/%d/%Y"), size: 8)
      draw_text_box(pdf, HEADER[:name], company_name, size: 8)
      draw_text_box(pdf, HEADER[:address], [ company_address_line1, company_address_line2 ].compact_blank.join(" "), size: 7.5)
      draw_text_box(pdf, HEADER[:city_state], company_city_state, size: 7.5)
      draw_text_box(pdf, HEADER[:zip], company_zip, size: 7.5)
      draw_text_box(pdf, HEADER[:employee_count], totals[:employee_count], size: 8, align: :center)
      draw_text_box(pdf, HEADER[:total_wages], money_string(totals[:total_wages]), size: 8, align: :right)
      draw_text_box(pdf, HEADER[:total_withheld], money_string(totals[:total_tax_withheld]), size: 8, align: :right)
      draw_text_box(pdf, HEADER[:page_current], page_number, size: 8, align: :center)
      draw_text_box(pdf, HEADER[:page_total], employee_pages.length, size: 8, align: :center)
    end

    def swica_totals
      employees = employee_pages.flatten
      return report.dig(:swica, :totals) || {} if fields[:employees].blank?

      {
        employee_count: employees.length,
        total_wages: employees.sum { |employee| employee[:swica_wages].to_f },
        total_tax_withheld: employees.sum { |employee| employee[:guam_withholding].to_f }
      }
    end

    def draw_employee_row(pdf, employee, index)
      y = 416.0 - (index * 33.0)
      draw_text_box(pdf, [ 36, y - 17, 164, y ], employee_ssn(employee), size: 7)
      draw_text_box(pdf, [ 168, y - 17, 360, y ], employee[:name], size: 7)
      draw_text_box(pdf, [ 365, y - 15, 522, y ], "", size: 6.5)
      draw_text_box(pdf, [ 365, y - 32, 522, y - 17 ], "", size: 6.5)
      draw_text_box(pdf, [ 526, y - 17, 626, y ], employee[:status].to_s.first&.upcase || "A", size: 7, align: :center)
      draw_text_box(pdf, [ 630, y - 17, 750, y ], money_string(employee[:swica_wages]), size: 7, align: :right)
      draw_text_box(pdf, [ 754, y - 17, 870, y ], money_string(employee[:guam_withholding]), size: 7, align: :right)
    end

    def employee_ssn(employee)
      digits = employee_ssn_digits.fetch(employee[:employee_id].to_i, nil)
      return "" if digits.blank?

      "#{digits[0, 3]}-#{digits[3, 2]}-#{digits[5, 4]}"
    end

    def employee_ssn_digits
      @employee_ssn_digits ||= begin
        employee_ids = employee_pages.flatten.filter_map { |employee| employee[:employee_id] }
        Employee.where(company_id: meta[:company_id], id: employee_ids).index_with(&:ssn_digits).transform_keys(&:id)
      end
    end
  end
end
