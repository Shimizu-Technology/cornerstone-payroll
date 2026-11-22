# frozen_string_literal: true

class EmployeeNote < ApplicationRecord
  MAX_BODY_LENGTH = 2000
  MAX_HIDDEN_REASON_LENGTH = 500

  SSN_PATTERN = /\b\d{3}-?\d{2}-?\d{4}\b/
  LONG_DIGIT_RUN_PATTERN = /\d{12,}/
  GROUPED_CARD_PATTERN = /\b(?:\d{4}[-\s]){3}\d{4}\b/

  IMMUTABLE_ATTRIBUTES = %w[company_id employee_id body created_by_id created_at].freeze

  belongs_to :company
  belongs_to :employee
  belongs_to :created_by, class_name: "User"
  belongs_to :hidden_by, class_name: "User", optional: true

  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  before_validation :normalize_attributes

  validates :body, presence: true, length: { maximum: MAX_BODY_LENGTH }
  validate :company_matches_employee
  validate :exclude_sensitive_patterns
  validate :hidden_fields_consistent
  validate :append_only_updates, on: :update

  before_destroy :prevent_destroy

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

  def exclude_sensitive_patterns
    validate_no_sensitive_data(:body, body)
    validate_no_sensitive_data(:hidden_reason, hidden_reason) if hidden_reason.present?
  end

  def validate_no_sensitive_data(attribute, value)
    return if value.blank?

    if value.match?(SSN_PATTERN)
      errors.add(
        attribute,
        "appears to contain an SSN or 9-digit tax ID. Do not enter SSNs, bank account numbers, or card numbers in staff notes."
      )
    elsif value.match?(LONG_DIGIT_RUN_PATTERN) || value.match?(GROUPED_CARD_PATTERN)
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
