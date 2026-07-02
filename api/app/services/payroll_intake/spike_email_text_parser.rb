# frozen_string_literal: true

require "csv"

module PayrollIntake
  class SpikeEmailTextParser
    HEADER_EMPLOYEE_PATTERNS = /\b(employee|name|team member|staff)\b/i
    HEADER_HOURS_PATTERNS = /\b(hour|hours|hr|hrs|regular|overtime|ot)\b/i
    HEADER_TIPS_PATTERNS = /\b(tip|tips|gratuity|gratuities)\b/i
    TOTAL_ROW_PATTERN = /\A\s*(total|grand total|subtotal)\b/i

    def initialize(text)
      @text = text.to_s
    end

    def call
      rows = parse_table_rows
      rows = parse_loose_rows if rows.empty?

      {
        rows: rows,
        detected_period: detected_period,
        warnings: []
      }
    end

    private

    attr_reader :text

    def lines
      @lines ||= text.lines.map { |line| line.gsub(/\u00A0/, " ").strip }.reject(&:blank?)
    end

    def detected_period
      range_match = text.match(%r{(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})\s*(?:-|to|through|–|—)\s*(\d{1,2}[/-]\d{1,2}[/-]\d{2,4})}i)
      return nil unless range_match

      {
        start_date: parse_date(range_match[1])&.iso8601,
        end_date: parse_date(range_match[2])&.iso8601
      }.compact
    end

    def parse_date(value)
      Date.strptime(value, "%m/%d/%Y")
    rescue Date::Error
      Date.strptime(value, "%m/%d/%y")
    rescue Date::Error
      Date.parse(value)
    rescue Date::Error
      nil
    end

    def parse_table_rows
      header_index = lines.index do |line|
        header_line?(line) && split_cells(line).length >= 3
      end
      return [] unless header_index

      header_cells = split_cells(lines[header_index]).map { |cell| normalize_header(cell) }
      return [] if header_cells.empty?

      lines[(header_index + 1)..].to_a.filter_map do |line|
        next if TOTAL_ROW_PATTERN.match?(line)

        cells = split_cells(line)
        next if cells.length < 2

        row_from_cells(header_cells, cells)
      end
    end

    def header_line?(line)
      HEADER_EMPLOYEE_PATTERNS.match?(line) && (HEADER_HOURS_PATTERNS.match?(line) || HEADER_TIPS_PATTERNS.match?(line))
    end

    def split_cells(line)
      if line.include?("\t")
        line.split(/\t+/).map(&:strip)
      elsif line.include?("|")
        line.split("|").map(&:strip)
      elsif looks_like_csv?(line)
        CSV.parse_line(line).to_a.map(&:strip)
      else
        line.split(/\s{2,}/).map(&:strip)
      end
    rescue CSV::MalformedCSVError
      line.split(/\s{2,}/).map(&:strip)
    end

    def looks_like_csv?(line)
      line.count(",") >= 2
    end

    def normalize_header(cell)
      header = cell.to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish
      return :employee_name if header.match?(/\b(employee|employee name|name|team member|staff)\b/)
      return :week1_hours if header.match?(/(week|wk)\s*1.*(hour|hours|hr|hrs)|first week.*(hour|hours|hr|hrs)|(hour|hours|hr|hrs).*(week|wk)\s*1/)
      return :week2_hours if header.match?(/(week|wk)\s*2.*(hour|hours|hr|hrs)|second week.*(hour|hours|hr|hrs)|(hour|hours|hr|hrs).*(week|wk)\s*2/)
      return :regular_hours if header.match?(/\b(regular|reg)\b.*\b(hour|hours|hr|hrs)\b|\bregular\b/)
      return :overtime_hours if header.match?(/\b(overtime|ot)\b/)
      return :total_hours if header.match?(/\b(total)\b.*\b(hour|hours|hr|hrs)\b|\bhours\b|\bhrs\b/)
      return :week1_tips if header.match?(/(week|wk)\s*1.*tip|first week.*tip|tip.*(week|wk)\s*1/)
      return :week2_tips if header.match?(/(week|wk)\s*2.*tip|second week.*tip|tip.*(week|wk)\s*2/)
      return :total_tips if header.match?(/\b(total|paid|reported)?\s*tip|tip\s*total|gratuity/)
      return :loan_deduction if header.match?(/loan|deduction/)

      nil
    end

    def row_from_cells(headers, cells)
      mapped = {}
      headers.each_with_index do |key, index|
        next unless key

        mapped[key] = cells[index]
      end

      name = mapped[:employee_name].to_s.strip
      return nil if name.blank?

      row = { employee_name: name, confidence: 0.95, source: "text_table" }
      %i[
        week1_hours week2_hours regular_hours overtime_hours total_hours
        week1_tips week2_tips total_tips loan_deduction
      ].each do |key|
        row[key] = numeric(mapped[key]) if mapped.key?(key)
      end
      row
    end

    def parse_loose_rows
      lines.filter_map do |line|
        parse_loose_row(line)
      end
    end

    def parse_loose_row(line)
      return nil if TOTAL_ROW_PATTERN.match?(line)
      return nil if header_line?(line)
      return nil unless line.match?(/\d/)

      first_number = line.index(/[$\d]/)
      return nil unless first_number && first_number > 1

      name = line[0...first_number].to_s.gsub(/^[•\-*\s]+/, "").strip
      return nil if name.blank? || name.length < 2

      money_values = line.scan(/\$\s*-?[\d,]+(?:\.\d+)?/).map { |value| numeric(value) }
      all_values = line.scan(/-?\$?\s*[\d,]+(?:\.\d+)?/).map { |value| numeric(value) }
      non_money_values = all_values.dup
      money_values.each do |money|
        idx = non_money_values.index { |value| (value - money).abs < 0.001 }
        non_money_values.delete_at(idx) if idx
      end

      return nil if all_values.empty?

      row = { employee_name: name, confidence: 0.70, source: "text_loose" }

      if non_money_values.length >= 2
        row[:week1_hours] = non_money_values[0]
        row[:week2_hours] = non_money_values[1]
      elsif non_money_values.length == 1
        row[:total_hours] = non_money_values[0]
      end

      if money_values.length >= 2
        row[:week1_tips] = money_values[-2]
        row[:week2_tips] = money_values[-1]
      elsif money_values.length == 1
        row[:total_tips] = money_values[0]
      elsif all_values.length >= 4
        row[:week1_tips] = all_values[-2]
        row[:week2_tips] = all_values[-1]
      end

      return nil if row.except(:employee_name, :confidence, :source).values.all? { |value| value.to_f.zero? }

      row
    end

    def numeric(value)
      return 0.0 if value.blank?

      BigDecimal(value.to_s.gsub(/[$,]/, "").strip).to_f
    rescue ArgumentError
      0.0
    end
  end
end
