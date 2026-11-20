# frozen_string_literal: true

# SSA identity and character rules shared by save-time and file preflight.
module Efw2Formatting
  extend self

  STATES = %w[AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY GU AS MP PR VI AA AE AP].freeze
  # Vendored from https://data.iana.org/TLD/tlds-alpha-by-domain.txt; no runtime network lookup.
  TLDS = File.readlines(Rails.root.join("vendor/iana/tlds-alpha-by-domain.txt"), chomp: true).reject { |line| line.start_with?("#") }.to_set.freeze
  ADDRESS_WIDTHS = { address_line1: 22, address_line2: 22, city: 22 }.freeze

  BAD_EIN_PREFIXES = %w[00 07 08 09 17 18 19 28 29 49 69 70 78 79 89].freeze

  class Problems < Array
    def initialize(scope:, employee_id: nil)
      super()
      @scope, @employee_id = scope, employee_id
    end

    def add(code, message)
      self << { scope: @scope, employee_id: @employee_id, code: code, message: message }
    end
  end

  def add_problem(problems, code, message)
    problems.is_a?(Problems) ? problems.add(code, message) : problems << message
  end

  def clean(value, name: false)
    text = transliterated(value).upcase
    text.gsub(name ? /[^A-Z '-]/ : /[^ -~]/, "").strip
  end

  def transliterated(value)
    ActiveSupport::Inflector.transliterate(value.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, "").gsub(/[ĐđØøŁłÆæŒœÐðÞþß]/, { "Đ" => "D", "đ" => "d", "Ø" => "O", "ø" => "o", "Ł" => "L", "ł" => "l", "Æ" => "AE", "æ" => "ae", "Œ" => "OE", "œ" => "oe", "Ð" => "D", "ð" => "d", "Þ" => "TH", "þ" => "th", "ß" => "ss" }).tr("’‘ʼ", "'''"))
  end

  def validate_text(object, label, fields, problems)
    fields.each do |field|
      text = transliterated(object.public_send(field))
      add_problem(problems, :text_unsupported, "#{label}: #{field.to_s.humanize.downcase} contains letters that cannot be written in the e-file; edit this field") if text.include?("?") || text.match?(/[^\x00-\x7F]/)
    end
  end

  def employer_problems(company, structured: false)
    problems = structured ? Problems.new(scope: :employer) : []
    validate_identity(company, "Employer", problems)
    validate_text(company, "Employer", %i[name address_line1 address_line2 city filing_contact_name], problems)
    validate_widths(company, "Employer", { name: 57, filing_contact_name: 27, establishment_number: 4 }, problems)
    add_problem(problems, :contact_name_missing, "Employer contact name is required") if clean(company.filing_contact_name).blank?
    add_problem(problems, :phone_invalid, "Employer contact phone must contain 10 digits") unless company.phone.to_s.gsub(/\D/, "").match?(/\A\d{10}\z/)
    add_problem(problems, :email_invalid, "Employer contact email is required and must fit 40 ASCII characters") unless valid_contact_email?(company.email)
    add_problem(problems, :filing_codes_invalid, "Invalid employer filing codes") unless %w[N F S T Y].include?(company.kind_of_employer) && %w[R F A M].include?(company.employment_code)
    problems
  end

  def valid_contact_email?(value)
    email = value.to_s
    return false unless email.ascii_only? && email.bytesize <= 40 && email.count("@") == 1

    local, domain = email.split("@", -1)
    return false if local.blank? || domain.blank? || email.include?("..") || local.start_with?(".") || local.end_with?(".")
    return false unless local.match?(/\A[A-Za-z0-9.~!#$%^&*_+{}|?'=\/`-]+\z/)

    labels = domain.split(".", -1)
    labels.length >= 2 && labels.all? { |label| label.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/) } && TLDS.include?(labels.last.upcase)
  end

  def validate_identity(object, label, problems)
    ein = object.ein.to_s.delete("-")
    add_problem(problems, :ein_invalid, "#{label}: valid nine-digit EIN required") unless ein.match?(/\A\d{9}\z/) && !BAD_EIN_PREFIXES.include?(ein[0, 2])
    add_problem(problems, :name_missing, "#{label}: name required") if clean(object.name).blank?
    validate_address(object, label, problems)
  end

  def validate_widths(object, label, widths, problems, name: false)
    widths.each do |field, width|
      if clean(object.public_send(field), name: name).length > width
        add_problem(problems, :field_too_long, "#{label}: #{field.to_s.humanize.downcase} exceeds the #{width}-character e-file field")
      end
    end
  end

  def validate_address(object, label, problems)
    validate_widths(object, label, ADDRESS_WIDTHS, problems)
    add_problem(problems, :address_missing, "#{label}: street and city required") if clean(object.address_line1).blank? || clean(object.city).blank?
    add_problem(problems, :state_invalid, "#{label}: Use the 2-letter code, e.g. GU") if object.state.to_s.strip.length > 2
    add_problem(problems, :address_invalid, "#{label}: valid US/territory state and ZIP required") unless STATES.include?(object.state.to_s.strip.upcase) && object.zip.to_s.strip.match?(/\A\d{5}(-?\d{4})?\z/)
  end
end
