# frozen_string_literal: true

# SSA Pub 42-007, tax year 2026, v4 (11/12/2026). Positions are one-based.
# Wages come exclusively from W2GuAggregator. This class formats and verifies.
class Efw2W2GuGenerator
  include Efw2Formatting

  class InvalidFile < ArgumentError
    attr_reader :problems
    def initialize(problems)
      @problems = problems
      super(problems.join("; "))
    end
  end

  RW_MONEY = [ 188, 199, 210, 221, 232, 243, 254, 276, 287, 298, 309, 320, 331, 353, 364, 375, 386, 408, 419, 430, 441, 452, 463, 474 ].freeze
  RT_MONEY = [ 10, 25, 40, 55, 70, 85, 100, 130, 145, 160, 175, 190, 205, 235, 250, 265, 280, 310, 340, 355, 370, 385, 295, 400 ].freeze
  RO_MONEY = ((12..89).step(11).to_a + (111..243).step(11).to_a + [ 275, 286, 297, 308, 319, 330, 341, 363, 374 ]).freeze
  RU_MONEY = ((10..115).step(15).to_a + [ 145 ] + (160..325).step(15).to_a + (355..475).step(15).to_a).freeze
  BOXES = %i[box1_wages_tips_other_comp box2_federal_income_tax_withheld box3_social_security_wages box4_social_security_tax_withheld box5_medicare_wages_tips box6_medicare_tax_withheld box7_social_security_tips].freeze
  BOX12 = { "D" => [ "RW", 287, "RT", 145 ], "AA" => [ "RW", 441, "RT", 370 ], "TA" => [ "RO", 221, "RU", 295 ], "TP" => [ "RO", 232, "RU", 310 ], "TT" => [ "RO", 243, "RU", 325 ] }.freeze

  attr_reader :report

  def initialize(company:, year:, submitter:, report: nil)
    @company, @year, @submitter = company, year.to_i, submitter
    @report = report || W2GuAggregator.new(company, year).generate
    @employees = company.employees.where(id: @report.fetch(:employees).pluck(:employee_id)).index_by(&:id)
  end

  def generate
    # The SSA/GuamTax wage file is an electronic filing; a demo never produces one.
    raise ArgumentError, Company::DEMO_UNAVAILABLE_MESSAGE if @company.demo?

    validate_inputs!
    records = [ submitter_record, employer_record ]
    report.fetch(:employees).each { |row| records.concat(employee_records(row)) }
    records << total_record("RT", "RW", records, RW_MONEY, RT_MONEY)
    records << total_record("RU", "RO", records, RO_MONEY, RU_MONEY)
    records << record("RF").tap { |r| put(r, 8, 9, report[:employees].length.to_s.rjust(9, "0")) }
    self_check!(records)
    records.join("\r\n") + "\r\n"
  end

  private

  def put(record, position, width, value)
    raise InvalidFile, [ "EFW2 field at position #{position} exceeds #{width} characters" ] if value.to_s.length > width

    record[position - 1, width] = value.to_s.ljust(width)
  end

  def money(record, position, width, cents)
    raise InvalidFile, [ "Amount is negative or exceeds the #{width}-digit EFW2 field" ] unless cents.between?(0, (10**width) - 1)

    put(record, position, width, cents.to_s.rjust(width, "0"))
  end

  def cents(value)
    (value.to_d * 100).round.to_i
  end

  def record(type)
    (" " * 512).tap { |r| put(r, 1, 2, type) }
  end

  def address(record, object, positions)
    line2, line1, city, state, zip, extension = positions
    put(record, line2, 22, clean(object.address_line2))
    put(record, line1, 22, clean(object.address_line1))
    put(record, city, 22, clean(object.city))
    put(record, state, 2, clean(object.state))
    digits = object.zip.to_s.strip.delete("-")
    put(record, zip, 5, digits[0, 5])
    put(record, extension, 4, digits[5, 4])
  end

  def submitter_record
    s = @submitter
    r = record("RA")
    put(r, 3, 9, s.ein.delete("-"))
    put(r, 12, 8, clean(s.bso_user_id))
    put(r, 29, 1, "0")
    put(r, 36, 2, "98")
    put(r, 38, 57, clean(s.name))
    address(r, s, [ 95, 117, 139, 161, 163, 168 ])
    put(r, 217, 57, clean(s.name))
    address(r, s, [ 274, 296, 318, 340, 342, 347 ])
    put(r, 396, 27, clean(s.contact_name))
    put(r, 423, 15, s.contact_phone.gsub(/\D/, ""))
    put(r, 446, 40, s.contact_email)
    put(r, 500, 1, "A")
    r
  end

  def employer_record
    r = record("RE")
    put(r, 3, 4, @year)
    put(r, 8, 9, @company.ein.delete("-"))
    put(r, 26, 1, "0")
    put(r, 27, 4, clean(@company.establishment_number))
    put(r, 40, 57, clean(@company.name))
    address(r, @company, [ 97, 119, 141, 163, 165, 170 ])
    put(r, 174, 1, @company.kind_of_employer)
    put(r, 219, 1, @company.employment_code)
    put(r, 220, 1, "G")
    put(r, 221, 1, "0")
    # The employer supplies its own filing contact; RA identifies the practice.
    put(r, 222, 27, clean(@company.filing_contact_name))
    put(r, 249, 15, @company.phone.gsub(/\D/, ""))
    put(r, 279, 40, @company.email)
    r
  end

  def employee_records(row)
    employee = @employees.fetch(row[:employee_id])
    rw, ro = record("RW"), record("RO")
    RW_MONEY.each { |p| money(rw, p, 11, 0) }
    RO_MONEY.each { |p| money(ro, p, 11, 0) }
    put(rw, 3, 9, employee.ssn_digits)
    [ [ 12, 15, employee.first_name ], [ 27, 15, employee.middle_name ], [ 42, 20, employee.last_name ], [ 62, 4, employee.name_suffix ] ].each do |p, w, value|
      put(rw, p, w, clean(value, name: true))
    end
    address(rw, employee, [ 66, 88, 110, 132, 134, 139 ])
    BOXES.each_with_index do |box, index|
      target, position = index < 2 ? [ ro, 363 + index * 11 ] : [ rw, 210 + (index - 2) * 11 ]
      money(target, position, 11, cents(row.fetch(box)))
    end
    Array(row[:box12]).each do |entry|
      type, position = BOX12.fetch(entry[:code])
      money(type == "RW" ? rw : ro, position, 11, cents(entry[:amount]))
    end
    put(rw, 486, 1, row[:box13_statutory_employee] ? "1" : "0")
    put(rw, 488, 1, row[:box13_retirement_plan] ? "1" : "0")
    put(rw, 489, 1, row[:box13_third_party_sick_pay] ? "1" : "0")
    occupation_codes = W2GuAggregator.box14b_codes(row[:box14b_tipped_occupation_codes])
    occupation_codes.select { Array(row[:box12]).any? { |e| e[:code] == "TP" && cents(e[:amount]).positive? } }.each_with_index { |code, i| put(rw, 490 + i * 3, 3, code) }
    [ rw, ro ]
  end

  def total_record(type, source, records, source_positions, total_positions)
    r = record(type)
    rows = records.select { |entry| entry.start_with?(source) }
    put(r, 3, 7, rows.length.to_s.rjust(7, "0"))
    money(r, 325, 15, 0) if type == "RT"
    source_positions.zip(total_positions).each do |p, t|
      money(r, t, 15, rows.sum { |entry| entry[p - 1, 11].to_i })
    end
    r
  end

  public

  def problems
    structured_problems.map { |problem| problem[:message] }
  end

  def structured_problems
    problems = []
    problems << "Only tax year 2026 is supported by this EFW2 layout" unless @year == 2026
    problems.map! { |message| { scope: :employer, employee_id: nil, code: :year_unsupported, message: message } }
    submitter_problems = Efw2Formatting::Problems.new(scope: :submitter)
    add_problem(submitter_problems, :submitter_missing, "Add the practice submitter profile") unless @submitter
    if @submitter
      @submitter.missing_fields.each { |field| add_problem(submitter_problems, :required_field_missing, "Submitter #{field} is required") }
      @submitter.errors.full_messages.each { |message| add_problem(submitter_problems, :submitter_validation, message) } unless @submitter.valid?
      validate_identity(@submitter, "Submitter", submitter_problems)
      validate_widths(@submitter, "Submitter", { name: 57, contact_name: 27 }, submitter_problems)
      validate_text(@submitter, "Submitter", %i[name address_line1 address_line2 city contact_name], submitter_problems)
      add_problem(submitter_problems, :email_invalid, "Submitter contact email must follow SSA email formatting rules") unless valid_contact_email?(@submitter.contact_email)
      add_problem(submitter_problems, :phone_invalid, "Submitter contact phone must contain 10 digits") unless @submitter.contact_phone.to_s.gsub(/\D/, "").match?(/\A\d{10}\z/)
    end
    problems.concat(submitter_problems)
    problems.concat(employer_problems(@company, structured: true))
    population_problems = Efw2Formatting::Problems.new(scope: :employee)
    add_problem(population_problems, :no_wage_records, "No employee wage records to export") if report[:employees].empty?
    ids = report[:employees].pluck(:employee_id)
    add_problem(population_problems, :duplicate_employee_rows, "Duplicate employee rows must be resolved") if ids.uniq.length != ids.length
    add_problem(population_problems, :employee_count_overflow, "Employee count exceeds the 7-digit EFW2 field") if ids.length > 9_999_999
    if report.dig(:meta, :employee_count) && report[:meta][:employee_count] != ids.length
      add_problem(population_problems, :employee_count_mismatch, "Aggregator employee count mismatch")
    end
    problems.concat(population_problems)
    ssns = @employees.values.map(&:ssn_digits).compact
    duplicate_ssns = ssns.tally.select { |_ssn, count| count > 1 }.keys
    duplicates = @employees.values.group_by(&:ssn_digits).slice(*duplicate_ssns).values
    duplicates.each do |group|
      group.each { |employee| problems << { scope: :employee, employee_id: employee.id, code: :ssn_duplicate, message: "#{[ employee.full_name, employee.name_suffix ].compact_blank.join(" ")}: duplicate SSN shared with #{group.reject { |other| other.id == employee.id }.map { |other| [ other.full_name, other.name_suffix ].compact_blank.join(" ") }.join(', ')}; correct the employee records" } }
    end
    report[:employees].each do |row|
      employee = @employees[row[:employee_id]]
      if !employee
        problems << { scope: :employee, employee_id: row[:employee_id], code: :employee_unavailable, message: "An employee wage record is unavailable; refresh the report" }
        next
      end
      employee_problems = Efw2Formatting::Problems.new(scope: :employee, employee_id: employee.id)
      label = [ employee.full_name, employee.name_suffix ].compact_blank.join(" ")
      validate_text(employee, label, %i[first_name middle_name last_name name_suffix address_line1 address_line2 city], employee_problems)
      add_problem(employee_problems, :ssn_invalid, "#{label}: valid SSN required") unless employee.ssn_digits.to_s.match?(/\A(?!000|666|9)\d{3}(?!00)\d{2}(?!0000)\d{4}\z/)
      add_problem(employee_problems, :employee_name_missing, "#{label}: first and last name required") if clean(employee.first_name, name: true).blank? || clean(employee.last_name, name: true).blank?
      validate_widths(employee, label, { first_name: 15, middle_name: 15, last_name: 20, name_suffix: 4 }, employee_problems, name: true)
      validate_address(employee, label, employee_problems)
      add_problem(employee_problems, :ss_wage_base_exceeded, "#{label}: Social Security wages plus tips exceed 2026 wage base") if cents(row[BOXES[2]]) + cents(row[BOXES[6]]) > 18_450_000
      add_problem(employee_problems, :ss_tax_max_exceeded, "#{label}: Social Security tax exceeds $11,439.00") if cents(row[BOXES[3]]) > 1_143_900
      BOXES.each_with_index do |box, i|
        amount = cents(row[box])
        add_problem(employee_problems, :box_amount_negative, "#{label}: Box #{i + 1} is negative") if amount.negative?
        add_problem(employee_problems, :box_amount_overflow, "#{label}: Box #{i + 1} exceeds the 11-digit e-file field") if amount > 99_999_999_999
      end
      ss_wages = cents(row[BOXES[2]]) + cents(row[BOXES[6]])
      add_problem(employee_problems, :medicare_wages_invalid, "#{label}: Box 5 Medicare wages must equal or exceed Box 3 wages plus Box 7 tips") if cents(row[BOXES[4]]) < ss_wages
      add_problem(employee_problems, :ss_wages_missing, "#{label}: Box 4 Social Security tax requires Box 3 wages or Box 7 tips") if cents(row[BOXES[3]]).positive? && ss_wages.zero?
      add_problem(employee_problems, :medicare_wages_missing, "#{label}: Box 6 Medicare tax requires Box 5 Medicare wages") if cents(row[BOXES[5]]).positive? && cents(row[BOXES[4]]).zero?
      Array(row[:box12]).each do |entry|
        amount = cents(entry[:amount])
        add_problem(employee_problems, :box12_amount_invalid, "#{label}: Box 12 #{entry[:code]} is negative or exceeds the 11-digit e-file field") unless amount.between?(0, 99_999_999_999)
      end
      Array(row[:box12]).each { |entry| add_problem(employee_problems, :box12_code_unsupported, "#{label}: unsupported Box 12 code #{entry[:code]}") unless BOX12.key?(entry[:code]) }
      entries = Array(row[:box12])
      add_problem(employee_problems, :box12_duplicate, "#{label}: duplicate Box 12 codes") if entries.pluck(:code).uniq.length != entries.length
      codes = Array(row[:box14b_tipped_occupation_codes])
      add_problem(employee_problems, :occupation_code_invalid, "#{label}: invalid tipped occupation codes") if codes.any? { |code| !code.to_s.match?(/\A\d{3}\z/) }
      problems.concat(employee_problems)
    end
    problems.uniq
  end

  private

  def validate_inputs!
    found = problems
    raise InvalidFile, found if found.any?
  end

  def self_check!(records)
    problems = []
    expected = [ "RA", "RE", *Array.new(report[:employees].length) { [ "RW", "RO" ] }.flatten, "RT", "RU", "RF" ]
    problems << "Record order/count mismatch" unless records.map { |r| r[0, 2] } == expected
    problems << "Records must be 512 ASCII bytes" unless records.all? { |r| r.bytesize == 512 && r.ascii_only? }
    { "RW" => [ RW_MONEY, RT_MONEY, "RT" ], "RO" => [ RO_MONEY, RU_MONEY, "RU" ] }.each do |type, (positions, totals, total_type)|
      rows = records.select { |r| r.start_with?(type) }
      total = records.find { |r| r.start_with?(total_type) }
      problems << "#{type} count mismatch" unless total[2, 7].to_i == rows.length
      positions.zip(totals).each { |p, t| problems << "#{total_type} total mismatch at #{t}" unless rows.sum { |r| r[p - 1, 11].to_i } == total[t - 1, 15].to_i }
    end
    BOXES.each_with_index do |box, i|
      type, position = i < 2 ? [ "RU", 460 + i * 15 ] : [ "RT", 40 + (i - 2) * 15 ]
      actual = records.find { |r| r.start_with?(type) }[position - 1, 15].to_i
      problems << "Aggregator total mismatch for #{box}" unless actual == cents(report[:totals].fetch(box))
    end
    BOX12.each do |code, (_, _, type, position)|
      key = "box12_code_#{code.downcase}_total".to_sym
      next unless report[:totals].key?(key)

      problems << "Aggregator Box 12 #{code} total mismatch" unless records.find { |r| r.start_with?(type) }[position - 1, 15].to_i == cents(report[:totals][key])
    end
    problems << "RF count mismatch" unless records.last[7, 9].to_i == report[:employees].length
    raise InvalidFile, problems if problems.any?
  end
end
