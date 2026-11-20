# frozen_string_literal: true

# IRS Pub 1220, tax year 2025, Rev. 5-2026, Part C. DRT's 2026 version
# remains to be confirmed. All positions are one-based. CR/LF occupies 749-750.
class Form1099Pub1220Generator
  class InvalidFile < ArgumentError
    attr_reader :problems
    def initialize(problems)
      @problems = problems
      super(problems.join("; "))
    end
  end

  # The payer's account number for a payee (B 21-40), also printed on the
  # official copies so paper and e-file match: "C" and the contractor's
  # record id, stable across years and corrections.
  def self.account_number(employee)
    "C#{employee.id.to_s.rjust(6, '0')}"
  end

  TCC_PROBLEM = "Add the transmitter control code (TCC) from DRT to download the final 1099 e-file. Drafts work without it."
  attr_reader :report

  def initialize(company:, year:, submitter:, draft:, report: nil)
    @company, @year, @submitter, @draft = company, year.to_i, submitter, draft
    @report = report || Form1099NecAggregator.new(company, year).generate
    # The rows the "1099s ready" sign-off covers (contractor records), so the
    # record counts and control totals match it. An unlinked one-off payee
    # decided "no 1099 due" is left out; one still undecided is a problem.
    @rows = Form1099NecFilingState.payee_rows(@report)
    @unresolved = Form1099NecFilingState.unresolved_one_off_rows(company: company, year: @year, report: @report)
    @excluded = @report.fetch(:reportable_contractors).reject { |row| row[:employee_id] }
    @people = company.employees.where(id: @rows.pluck(:employee_id)).index_by(&:id)
  end

  def generate
    found = problems
    raise InvalidFile, found if found.any?

    records = [ transmitter, payer, *@rows.map { |row| payee(row) }, totals, ending ]
    records.each_with_index { |r, i| number(r, 500, 8, i + 1) }
    self_check!(records)
    records.join
  end

  def problems
    found = []
    found << "Only tax year 2026 is supported" unless @year == 2026
    found << "No reportable 1099 payees" if @rows.empty? && @unresolved.empty?
    found << TCC_PROBLEM if !@draft && @submitter&.tcc.blank?
    found << "Add the practice submitter profile" unless @submitter
    found.concat(entity_problems(@company, "Payer"))
    if @submitter
      found.concat(entity_problems(@submitter, "Transmitter"))
      found << "Transmitter: contact name required" if @submitter.contact_name.blank?
      found << "Transmitter: contact phone must contain 10 digits" unless tin(@submitter.contact_phone).match?(/\A\d{10}\z/)
      found << "Transmitter: invalid TCC" if @submitter.tcc.present? && !@submitter.tcc.match?(/\A[A-Za-z0-9]{5}\z/)
    end
    found.concat(payee_problems)
  end

  # What the client's own records must satisfy for this e-file: the payer
  # and every payee. The transmitter (the practice's submitter profile) is
  # checked when the file is made. "Mark 1099s ready" refuses a sign-off
  # these would refuse, so every signed-off client can download its final file.
  def client_problems
    entity_problems(@company, "Payer") + payee_problems
  end

  def payee_problems
    found = @unresolved.map do |row|
      "#{row[:name]}: missing TIN and address; link this one-off payee to a contractor, or record that no 1099 is due, before exporting"
    end
    @rows.each do |row|
      person = @people[row[:employee_id]]
      label = row[:name]
      unless person
        found << "#{label}: the contractor record could not be found"
        next
      end
      id = row[:tin_type] == "EIN" ? tin(person.contractor_ein) : person.ssn_digits.to_s
      found << "#{label}: valid #{row[:tin_type]} required" unless id.match?(/\A\d{9}\z/) && id.chars.uniq.length > 1
      found << "#{label}: valid SSN required" if row[:tin_type] == "SSN" && !person.valid_filing_ssn?
      found << "#{label}: unknown TIN type" unless row[:tin_type].in?(%w[SSN EIN])
      identity_problems(person, label, found)
      [ person.first_name, person.last_name, person.middle_name, person.business_name ].each { |name| validate_field(name, 80, label, "name", found) }
      payee_names(person, row).each_with_index { |name, i| validate_field(name, 40, label, "payee name line #{i + 1}", found) }
      found << "#{label}: payee name contains no usable letters or numbers" if payee_names(person, row).first.to_s !~ /[A-Z0-9]/
      validate_field(name_control(person), 4, label, "name control", found) unless row[:tin_type] == "EIN"
    end
    ids = @rows.map { |row| row[:employee_id] }.compact
    found << "Duplicate payee rows" unless ids.uniq.length == ids.length
    found
  end

  def entity_problems(object, label)
    found = []
    found << "#{label}: valid EIN required" unless tin(object.ein).match?(/\A\d{9}\z/) && tin(object.ein).chars.uniq.length > 1
    identity_problems(object, label, found)
    found
  end

  # Public so corruption tests can independently exercise the return barrier.
  def self_check!(records)
    found = []
    found << "Records must be exactly 750 ASCII bytes with CR/LF in 749-750" unless records.all? { |r| r.bytesize == 750 && r.ascii_only? && r.end_with?("\r\n") }
    found << "Record order/count mismatch" unless records.map { |r| r[0] } == [ "T", "A", *Array.new(@rows.length, "B"), "C", "F" ]
    raise InvalidFile, found if found.any?

    found << "Payment fields must contain digits" unless records.select { |r| r.start_with?("B") }.all? { |r| r[54, 216].match?(/\A\d{216}\z/) }
    found << "Record sequence mismatch" unless records.each_with_index.all? { |r, i| r[499, 8] == (i + 1).to_s.rjust(8, "0") }
    bs = records.select { |r| r.start_with?("B") }
    c, f = records[-2], records[-1]
    found << "Payee counts mismatch" unless [ records.first[295, 8], c[1, 8], f[49, 8] ].all? { |v| v == bs.length.to_s.rjust(8, "0") }
    found << "Payer count mismatch" unless f[1, 8] == "00000001"
    (0...18).each do |i|
      actual = c[15 + i * 18, 18]
      sum = bs.sum { |r| r[54 + i * 12, 12].to_i }
      found << "C amount total mismatch for code #{i + 1}" unless actual == sum.to_s.rjust(18, "0")
    end
    # The aggregator's totals, less the one-off payees decided "no 1099 due".
    expected_box1 = cents(report.fetch(:totals).fetch(:reportable_compensation)) - @excluded.sum { |row| cents(row.fetch(:total_compensation)) }
    expected_box4 = cents(report.fetch(:totals).fetch(:reportable_federal_withheld)) - @excluded.sum { |row| cents(row.fetch(:federal_withheld)) }
    found << "Aggregator Box 1 total mismatch" unless c[15, 18].to_i == expected_box1
    found << "Aggregator Box 4 total mismatch" unless c[69, 18].to_i == expected_box4
    raise InvalidFile, found if found.any?

    true
  end

  private

  def identity_problems(object, label, found)
    unless object.is_a?(Employee)
      validate_field(object.name, 40, label, "name", found)
      found << "#{label}: name contains no usable letters or numbers" unless Efw2Formatting.clean(object.name).match?(/[A-Z0-9]/)
    end
    validate_field([ object.address_line1, object.address_line2 ].compact_blank.join(" "), 40, label, "address", found)
    validate_field(object.city, 40, label, "city", found)
    validate_field(tin(object.phone), 15, label, "phone", found) if object == @company
    if object == @submitter
      validate_field(object.contact_name, 40, label, "contact name", found)
      validate_field(object.contact_email, 50, label, "contact email", found, raw: true)
    end
    found << "#{label}: name required" if object.respond_to?(:name) ? object.name.blank? : object.full_name.blank?
    found << "#{label}: complete address required" if [ object.address_line1, object.city, object.state, object.zip ].any?(&:blank?)
    found << "#{label}: unsupported state/territory or ZIP" unless object.state.to_s.upcase.in?(Efw2Formatting::STATES) && object.zip.to_s.match?(/\A\d{5}(-?\d{4})?\z/)
  end

  def validate_field(value, width, label, field, found, raw: false)
    text = raw ? value.to_s : Efw2Formatting.transliterated(value)
    if text.include?("?") || !text.ascii_only? || value.to_s.match?(/[\r\n]/)
      found << "#{label}: the #{field} contains unsupported characters — edit the profile."
      return
    end
    text = raw ? value.to_s : clean(value)
    found << "#{label}: the #{field} is longer than #{width} characters — shorten it on the profile." if text.bytesize > width
  end

  # Exhibit 1: use the first surname, retaining leading surname particles.
  def name_control(person)
    self.class.name_control(person)
  end

  def self.name_control(person)
    words = person.last_name.to_s.split("-").first.to_s.split
    particle = words.join(" ").match(/\A(?:de la|de las|de los|del|de|san|santa|st)\s+/i)
    surname = particle ? words.take(particle[0].split.length + 1).join(" ") : words.first.to_s
    Efw2Formatting.clean(surname).delete(".'").gsub(/[^A-Z0-9]/, "")[0, 4]
  end

  # SSN: individual first, business second. EIN: business first. A long
  # primary name may continue onto line 2 only when it is otherwise unused,
  # and line 1 must end with a whole word (B 288-327). A single word longer
  # than 40 characters is left whole, so preflight refuses it by name.
  def payee_names(person, row)
    self.class.payee_name_lines(person, row[:tin_type])
  end

  # Public so Form1099InputsFingerprint binds the exact name lines printed.
  def self.payee_name_lines(person, tin_type)
    primary = tin_type == "EIN" ? person.business_name.presence || person.full_name : "#{person.last_name} #{person.first_name} #{person.middle_name}".strip
    secondary = tin_type == "SSN" ? person.business_name.to_s : ""
    names = [ primary, secondary ].map { |v| Efw2Formatting.clean(v).delete(".'").gsub(/[^A-Z0-9 &-]/, "") }
    if names[0].length > 40 && names[1].blank?
      split_at = names[0][0, 41].rindex(" ")
      names = [ names[0][0, split_at], names[0][split_at..].lstrip ] if split_at
    end
    names
  end

  def clean(value)
    text = Efw2Formatting.transliterated(value)
    raise InvalidFile, [ "Text contains unsupported characters; edit the payer, transmitter or payee details" ] if text.include?("?") || text.match?(/[^\x00-\x7F]/)

    Efw2Formatting.clean(value).delete(".'")
  end

  def tin(value)
    value.to_s.gsub(/\D/, "")
  end

  def cents(value)
    (value.to_d * 100).round.to_i
  end

  def record(type)
    (type + " " * 747 + "\r\n")
  end

  def put(r, position, width, value)
    text = value.to_s
    raise InvalidFile, [ "Field at #{position} exceeds #{width} characters or contains unsupported text" ] if text.bytesize > width || !text.ascii_only? || text.match?(/[\r\n]/)

    r[position - 1, width] = text.ljust(width)
  end

  def number(r, p, w, n)
    raise InvalidFile, [ "Invalid amount/count at #{p}" ] unless n.between?(0, 10**w - 1)

    put(r, p, w, n.to_s.rjust(w, "0"))
  end

  def address(r, object, street, city, state, zip)
    put(r, street, 40, clean([ object.address_line1, object.address_line2 ].compact_blank.join(" ")))
    put(r, city, 40, clean(object.city))
    put(r, state, 2, clean(object.state))
    put(r, zip, 9, tin(object.zip))
  end

  def transmitter
    s = @submitter
    record("T").tap do |r|
      put(r, 2, 4, @year)
      put(r, 7, 9, tin(s.ein))
      put(r, 16, 5, s.tcc.present? ? s.tcc.upcase : "TEST0")
      put(r, 28, 1, @draft ? "T" : "")
      put(r, 30, 40, clean(s.name))
      put(r, 110, 40, clean(s.name))
      address(r, s, 190, 230, 270, 272)
      number(r, 296, 8, @rows.length)
      put(r, 304, 40, clean(s.contact_name))
      put(r, 344, 15, tin(s.contact_phone))
      put(r, 359, 50, s.contact_email)
      put(r, 518, 1, "I")
      # Part C section 1 forbids punctuation in transmitter names/addresses.
      [ 30, 110, 190, 230, 304 ].each do |position|
        put(r, position, 40, r[position - 1, 40].gsub(/[^A-Z0-9 ]/, "").strip)
      end
    end
  end

  def payer
    record("A").tap do |r|
      put(r, 2, 4, @year)
      put(r, 12, 9, tin(@company.ein))
      put(r, 26, 2, "NE")
      put(r, 28, 18, "14")
      put(r, 53, 40, clean(@company.name))
      put(r, 133, 1, "0")
      address(r, @company, 134, 174, 214, 216)
      put(r, 225, 15, tin(@company.phone))
    end
  end

  def payee(row)
    person = @people.fetch(row[:employee_id])
    ein = row[:tin_type] == "EIN"
    names = payee_names(person, row)
    record("B").tap do |r|
      put(r, 2, 4, @year)
      # Business name controls have entity-specific rules: blanks are expressly allowed.
      put(r, 7, 4, ein ? "" : name_control(person))
      put(r, 11, 1, ein ? "1" : "2")
      put(r, 12, 9, ein ? tin(person.contractor_ein) : person.ssn_digits)
      # Stable issuer account number lets corrections match the original payee.
      put(r, 21, 20, self.class.account_number(person))
      (0...18).each { |i| number(r, 55 + i * 12, 12, 0) }
      number(r, 55, 12, cents(row.fetch(:total_compensation)))
      number(r, 91, 12, cents(row.fetch(:federal_withheld)))
      put(r, 288, 40, names[0])
      put(r, 328, 40, names[1])
      address(r, person, 368, 448, 488, 490)
      number(r, 723, 12, 0)
      number(r, 735, 12, 0)
    end
  end

  def totals
    record("C").tap do |r|
      number(r, 2, 8, @rows.length)
      (0...18).each { |i| number(r, 16 + i * 18, 18, 0) }
      number(r, 16, 18, @rows.sum { |row| cents(row.fetch(:total_compensation)) })
      number(r, 70, 18, @rows.sum { |row| cents(row.fetch(:federal_withheld)) })
    end
  end

  def ending
    record("F").tap do |r|
      number(r, 2, 8, 1)
      number(r, 10, 21, 0)
      number(r, 50, 8, @rows.length)
    end
  end
end
