# frozen_string_literal: true

class SwicaAsciiExporter
  RECORD_LENGTH = 275

  # Guam DRT SWICA booklet, Code W wage record only. This exporter intentionally
  # does not claim to produce a filing upload because the prescribed file also
  # requires A, B, T, and F records that Cornerstone does not yet generate.
  # - positions 78-112: "City and State or U.S. Possession" (single 35-char field)
  # - positions 113-117: Foreign Postal Code, blank for Guam/U.S. addresses
  # - positions 118-126: ZIP Code
  CITY_STATE_POSITION = 78
  CITY_STATE_LENGTH = 35
  FOREIGN_POSTAL_CODE_POSITION = 113
  FOREIGN_POSTAL_CODE_LENGTH = 5
  ZIP_POSITION = 118
  ZIP_LENGTH = 9

  def initialize(report)
    @report = report.deep_symbolize_keys
    @company_id = @report.dig(:meta, :company_id)
    @year = @report.dig(:meta, :year).to_i
    @quarter = @report.dig(:meta, :quarter).to_i
  end

  def filename
    "swica_wage_records_draft_#{@year}_q#{@quarter}.txt"
  end

  def generate
    rows = employees.map { |row| wage_record(row) }
    validate_record_lengths!(rows)
    rows.join("\r\n") + "\r\n"
  end

  private

  attr_reader :company_id, :year, :quarter, :report

  def employees
    Array(report.dig(:swica, :employees))
  end

  def wage_record(row)
    employee = employees_by_id.fetch(row[:employee_id].to_i)
    fields = Array.new(RECORD_LENGTH, " ")
    put(fields, 1, "W")
    put(fields, 2, digits(employee.ssn_digits).presence || "000000000", length: 9, align: :right, pad: "0")
    put(fields, 11, employee.full_name.upcase, length: 27)
    put(fields, 38, employee.address_line1.to_s.upcase, length: 40)
    put(fields, CITY_STATE_POSITION, [ employee.city, employee.state.presence || "GU" ].compact_blank.join(" ").upcase, length: CITY_STATE_LENGTH)
    put(fields, FOREIGN_POSTAL_CODE_POSITION, "", length: FOREIGN_POSTAL_CODE_LENGTH)
    put(fields, ZIP_POSITION, digits(employee.zip), length: ZIP_LENGTH)
    put(fields, 127, employee.status == "terminated" ? "T" : "A")
    put(fields, 128, employee.termination_date&.strftime("%m%d%y").to_s, length: 6)
    put(fields, 134, quarter.to_s)
    put(fields, 135, year.to_s.last(2), length: 2)
    put(fields, 137, cents(row[:swica_wages]), length: 9, align: :right, pad: "0")
    put(fields, 146, cents(row[:guam_withholding]), length: 9, align: :right, pad: "0")
    put(fields, 155, employee.date_of_birth&.strftime("%m%d%y").to_s, length: 6)
    put(fields, 275, "S")
    fields.join
  end

  def employees_by_id
    @employees_by_id ||= Employee.where(company_id: company_id, id: employees.map { |row| row[:employee_id] }).index_by(&:id)
  end

  def put(fields, one_based_position, value, length: 1, align: :left, pad: " ")
    text = ascii(value)[0, length]
    text = align == :right ? text.rjust(length, pad) : text.ljust(length, pad)
    text.chars.each_with_index { |char, index| fields[one_based_position - 1 + index] = char }
  end

  def ascii(value)
    ActiveSupport::Inflector.transliterate(value.to_s).encode("ASCII", invalid: :replace, undef: :replace, replace: "?")
  end

  def cents(value)
    (BigDecimal(value.to_s) * 100).round(0).to_i.to_s
  end

  def digits(value)
    value.to_s.gsub(/\D/, "")
  end

  def validate_record_lengths!(rows)
    bad = rows.find { |row| row.length != RECORD_LENGTH || row.bytesize != RECORD_LENGTH }
    raise ArgumentError, "SWICA record length must be #{RECORD_LENGTH} ASCII bytes" if bad
  end
end
