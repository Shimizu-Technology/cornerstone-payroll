# frozen_string_literal: true

# SSA identity and character rules shared by save-time and file preflight.
module Efw2Formatting
  extend self

  STATES = %w[AL AK AZ AR CA CO CT DE DC FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT VA WA WV WI WY GU AS MP PR VI AA AE AP].freeze
  BAD_EIN_PREFIXES = %w[00 07 08 09 17 18 19 28 29 49 69 70 78 79 89].freeze

  def clean(value, name: false)
    text = ActiveSupport::Inflector.transliterate(value.to_s.tr("’‘ʼ", "'''")).upcase
    text.gsub(name ? /[^A-Z '-]/ : /[^ -~]/, "").strip
  end

  def valid_contact_email?(value)
    email = value.to_s
    return false unless email.ascii_only? && email.bytesize <= 40 && email.count("@") == 1

    local, domain = email.split("@", -1)
    return false if local.blank? || domain.blank? || email.include?("..") || local.start_with?(".") || local.end_with?(".")
    return false unless local.match?(/\A[A-Za-z0-9.~!#$%^&*_+{}|?'=\/`-]+\z/)

    labels = domain.split(".", -1)
    labels.length >= 2 && labels.all? { |label| label.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/) } && labels.last.match?(/\A[A-Za-z]{2,}\z/)
  end

  def validate_identity(object, label, problems)
    ein = object.ein.to_s.delete("-")
    problems << "#{label}: valid nine-digit EIN required" unless ein.match?(/\A\d{9}\z/) && !BAD_EIN_PREFIXES.include?(ein[0, 2])
    problems << "#{label}: name required" if clean(object.name).blank?
    validate_address(object, label, problems)
  end

  def validate_address(object, label, problems)
    problems << "#{label}: street and city required" if clean(object.address_line1).blank? || clean(object.city).blank?
    problems << "#{label}: valid US/territory state and ZIP required" unless STATES.include?(object.state.to_s.upcase) && object.zip.to_s.match?(/\A\d{5}(-?\d{4})?\z/)
  end
end
