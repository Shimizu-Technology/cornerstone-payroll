# frozen_string_literal: true

# A person employees can ask about their pay or the employee app, shown on the
# company's Help screen. Set by the client's own admins or Cornerstone.
#
# Served only to signed-in employees of the company. Never add these to the
# public tenant branding response.
class CompanyHelpContact < ApplicationRecord
  MAX_CONTACTS = 5
  NAME_MAX = 80
  ROLE_MAX = 60
  EMAIL_PATTERN = /\A[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+\z/
  PHONE_PATTERN = /\A\+?[\d\s().-]+\z/

  belongs_to :company, inverse_of: :help_contacts

  before_validation :normalize_fields

  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_CONTACTS }
  validates :name, presence: true, length: { maximum: NAME_MAX }
  validates :role, length: { maximum: ROLE_MAX }, allow_nil: true
  validates :email, length: { maximum: 254 }, format: { with: EMAIL_PATTERN, message: "doesn't look like an email address" }, allow_nil: true
  validate :phone_is_dialable
  validate :reachable
  validate :plain_text

  def phone_digits
    phone.to_s.gsub(/\D/, "")
  end

  def as_help_json
    { name: name, role: role, phone: phone, email: email, text_ok: text_ok }
  end

  private

  def normalize_fields
    self.name = name.to_s.squish.presence
    self.role = role.to_s.squish.presence
    self.phone = phone.to_s.squish.presence
    self.email = email.to_s.strip.downcase.presence
    self.text_ok = false if phone.nil?
  end

  def phone_is_dialable
    return if phone.nil?
    return errors.add(:phone, "can use only digits, spaces, dashes, dots, brackets and a leading +") unless phone.match?(PHONE_PATTERN)

    errors.add(:phone, "needs 7 to 15 digits") unless phone_digits.length.between?(7, 15)
  end

  def reachable
    errors.add(:base, "Add a phone number or an email so employees can reach #{name.presence || 'this person'}") if phone.nil? && email.nil?
  end

  def plain_text
    %i[name role].each do |field|
      errors.add(field, "can't contain < or >") if self[field].to_s.match?(/[<>[:cntrl:]]/)
    end
  end
end
