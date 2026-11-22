# frozen_string_literal: true

class EmployeeNote < ApplicationRecord
  MAX_BODY_LENGTH = 2000
  MAX_HIDDEN_REASON_LENGTH = 500

  # Separated SSN (3-2-4 with one consistent separator: hyphen, space, or dot).
  # Digit/hyphen lookarounds avoid matching embedded fragments, ZIP+4 (5-4),
  # EINs (2-7), or phone numbers (3-3-4).
  SSN_SEPARATED_PATTERN = /(?<![\d-])\d{3}([- .])\d{2}\1\d{4}(?![\d-])/

  # Bare 9-digit runs are ambiguous with unformatted EINs (e.g. 660970313) and
  # reference IDs, so flag them as SSNs only when adjacent to SSN/TIN wording
  # (including glued forms like SSN123456789, abbreviations like "SSN no.", and
  # a single line break, while keeping ";" as a clause boundary).
  SSN_CONTEXT_BEFORE_PATTERN =
    /\b(?:ssn|social\s+security|ss#|itin|tin|tax\s*id)(?=\d|[^a-zA-Z])[^0-9\r\n;]{0,20}?(?:\r?\n[^0-9\r\n;]{0,10}?)?(?<!\d)\d{9}(?!\d)/i
  SSN_CONTEXT_AFTER_PATTERN =
    /(?<!\d)\d{9}(?!\d)[^0-9\r\n;]{0,12}?(?:\r?\n[^0-9\r\n;]{0,8}?)?\b(?:ssn|social\s+security|ss#|itin|tin|tax\s*id)(?![a-zA-Z])/i

  # Flag 10-17 digit account numbers near bank/DD keywords (and 9-digit routing
  # numbers near routing/ABA keywords) so 10-digit phone numbers and unformatted
  # EINs are not false positives. A bare 10-digit Guam phone number (671xxxxxxx)
  # is accepted near general bank/DD prose unless an account keyword sits
  # directly before it.
  GUAM_PHONE_PATTERN = /\A671\d{7}\z/
  BANK_ACCOUNT_BEFORE_PATTERN =
    /\b(?:acct\.?|account|routing|aba|dd|direct\s+deposit|bank|checking|savings)(?=\d|[^a-zA-Z])[^0-9\r\n;]{0,25}?(?:\r?\n[^0-9\r\n;]{0,10}?)?(?<!\d)(\d{10,17})(?!\d)/i
  BANK_ACCOUNT_AFTER_PATTERN =
    /(?<!\d)(\d{10,17})(?!\d)[^0-9\r\n;]{0,15}?(?:\r?\n[^0-9\r\n;]{0,8}?)?\b(?:acct\.?|account|routing|aba|dd|direct\s+deposit|bank|checking|savings)(?![a-zA-Z])/i
  DIRECT_ACCOUNT_BEFORE_PATTERN =
    /\b(?:acct\.?|account|routing|aba|checking|savings)(?:(?=\d)|(?:[ \t]*(?:no\.?|num\.?|number|ending(?:[ \t]+in)?))?[ \t:#-]{0,5}(?:\r?\n[ \t:#-]{0,5})?)(?<!\d)\d{10,17}(?!\d)/i
  # An account keyword right after the number ("6715551234 is the account
  # number") counts even for a Guam-phone-shaped number.
  DIRECT_ACCOUNT_AFTER_PATTERN =
    /(?<!\d)\d{10,17}(?!\d)[ \t]{0,3}(?:(?:is|was)[ \t]+(?:the|my|her|his|their|our)[ \t]+)?(?:acct\.?|account|routing|aba|checking|savings)(?![a-zA-Z])/i
  ROUTING_BEFORE_PATTERN =
    /\b(?:routing|aba)(?=\d|[^a-zA-Z])[^0-9\r\n;]{0,20}?(?:\r?\n[^0-9\r\n;]{0,10}?)?(?<!\d)\d{9}(?!\d)/i
  ROUTING_AFTER_PATTERN =
    /(?<!\d)\d{9}(?!\d)[^0-9\r\n;]{0,12}?(?:\r?\n[^0-9\r\n;]{0,8}?)?\b(?:routing|aba)(?![a-zA-Z])/i

  # Card-number shapes: 13-19 bare digits, or standard grouped card layouts
  # (4-4-4-4, 4-4-4-4-3, Amex 4-6-5, and Diners 4-6-4) using one consistent separator so
  # year lists, ZIP lists, 4-4-4 refs, and ISO dates do not false-positive.
  CARD_BARE_PATTERN = /(?<![\d-])\d{13,19}(?![\d-])/
  CARD_GROUPED_PATTERN =
    /(?<![\d-])(?:\d{4}([- ])\d{4}\1\d{4}\1\d{4}(?:\1\d{3})?|\d{4}([- ])\d{6}\2\d{4,5})(?![\d-])/

  IMMUTABLE_ATTRIBUTES = %w[company_id employee_id body created_by_id created_at].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :created_by, class_name: "User"
  belongs_to :hidden_by, class_name: "User", optional: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  before_validation :normalize_attributes

  validates :body, presence: true, length: { maximum: MAX_BODY_LENGTH }
  validate :company_matches_employee
  validate :exclude_sensitive_body_patterns, on: :create
  validate :exclude_sensitive_hidden_reason_patterns, if: :should_validate_hidden_reason_sensitive_patterns?
  validate :hidden_fields_consistent
  validate :append_only_updates, on: :update

  before_destroy :prevent_destroy

  def self.sensitive_data_kind(value)
    return nil if value.blank?

    # Treat no-break and narrow spaces as ordinary spaces so Ruby's \s matches
    # what JavaScript's \s already matches.
    text = value.to_s.tr("\u00A0\u2007\u202F", "   ")
    return :ssn if contains_ssn?(text)
    return :bank_or_card if contains_bank_account?(text) || contains_card_number?(text)

    nil
  end

  def self.contains_ssn?(text)
    text.match?(SSN_SEPARATED_PATTERN) ||
      text.match?(SSN_CONTEXT_BEFORE_PATTERN) ||
      text.match?(SSN_CONTEXT_AFTER_PATTERN)
  end

  def self.contains_bank_account?(text)
    return true if text.match?(DIRECT_ACCOUNT_BEFORE_PATTERN) ||
                   text.match?(DIRECT_ACCOUNT_AFTER_PATTERN) ||
                   text.match?(ROUTING_BEFORE_PATTERN) ||
                   text.match?(ROUTING_AFTER_PATTERN)

    matches_non_guam_phone_bank_account?(text, BANK_ACCOUNT_BEFORE_PATTERN) ||
      matches_non_guam_phone_bank_account?(text, BANK_ACCOUNT_AFTER_PATTERN)
  end

  def self.matches_non_guam_phone_bank_account?(text, pattern)
    text.enum_for(:scan, pattern).any? do
      digits = Regexp.last_match[1]
      !digits.match?(GUAM_PHONE_PATTERN)
    end
  end

  def self.contains_card_number?(text)
    text.match?(CARD_BARE_PATTERN) || text.match?(CARD_GROUPED_PATTERN)
  end

  def hidden?
    hidden_at.present?
  end

  def hide!(actor:, reason:)
    if hidden?
      errors.add(:base, "Note is already hidden")
      raise ActiveRecord::RecordInvalid, self
    end

    update!(
      hidden_at: Time.current,
      hidden_by: actor,
      hidden_reason: reason.to_s.strip
    )
  end

  private

  def normalize_attributes
    self.body = body.strip if new_record? && body.is_a?(String)
    self.hidden_reason = hidden_reason.strip.presence if hidden_reason_changed? && hidden_reason.is_a?(String)
  end

  def company_matches_employee
    return unless employee && company_id != employee.company_id

    errors.add(:company, "must match the employee's company")
  end

  def should_validate_hidden_reason_sensitive_patterns?
    hidden_reason.present? && (new_record? || will_save_change_to_hidden_reason?)
  end

  def exclude_sensitive_body_patterns
    add_sensitive_data_error(:body, body)
  end

  def exclude_sensitive_hidden_reason_patterns
    add_sensitive_data_error(:hidden_reason, hidden_reason)
  end

  def add_sensitive_data_error(attribute, value)
    case self.class.sensitive_data_kind(value)
    when :ssn
      errors.add(
        attribute,
        "appears to contain an SSN or 9-digit tax ID. Do not enter SSNs, bank account numbers, or card numbers in staff notes."
      )
    when :bank_or_card
      errors.add(
        attribute,
        "appears to contain a bank account or card number. Do not enter SSNs, bank account numbers, or card numbers in staff notes."
      )
    end
  end

  def hidden_fields_consistent
    if hidden_at.present?
      errors.add(:hidden_by, "must be present when hiding a note") if hidden_by.blank?
      if hidden_reason.blank?
        errors.add(:hidden_reason, "is required to hide a note")
      elsif hidden_reason.length > MAX_HIDDEN_REASON_LENGTH
        errors.add(:hidden_reason, "is too long (maximum is #{MAX_HIDDEN_REASON_LENGTH} characters)")
      end
    else
      errors.add(:hidden_by, "cannot be set unless the note is hidden") if hidden_by_id.present?
      errors.add(:hidden_reason, "cannot be set unless the note is hidden") if hidden_reason.present?
    end
  end

  def append_only_updates
    IMMUTABLE_ATTRIBUTES.each do |attribute|
      next unless will_save_change_to_attribute?(attribute)

      if attribute == "body"
        errors.add(:body, "cannot be edited; add a new note instead")
      else
        errors.add(attribute.to_sym, "cannot be changed after creation")
      end
    end

    return unless hidden_at_was.present?

    errors.add(:base, "Hidden notes cannot be modified")
  end

  def prevent_destroy
    errors.add(:base, "Employee notes cannot be deleted; hide the note instead")
    throw :abort
  end
end
