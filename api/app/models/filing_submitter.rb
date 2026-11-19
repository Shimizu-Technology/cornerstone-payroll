# frozen_string_literal: true

# One practice profile per organization. Future transmitter identifiers belong here;
# credentials and passwords do not.
class FilingSubmitter < ApplicationRecord
  FIELDS = %i[ein name address_line1 address_line2 city state zip contact_name contact_phone contact_email bso_user_id].freeze
  belongs_to :organization
  validates :organization_id, uniqueness: true
  validates :ein, format: { with: /\A\d{2}-?\d{7}\z/ }, allow_blank: true
  validates :bso_user_id, format: { with: /\A[A-Za-z0-9]{8}\z/ }, allow_blank: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: 40 }, allow_blank: true
  validates :contact_phone, format: { with: /\A[\d ()+.-]{10,25}\z/ }, allow_blank: true

  validate :ssa_format

  def filing_problems
    valid?
    missing_fields.map { |field| "Add #{field.to_s.humanize.downcase}" } + errors.full_messages
  end

  def ssa_format
    # Use precisely the transmitter checks used when writing RA.
    validator = Efw2Formatting
    found = []
    validator.validate_identity(self, "Submitter", found)
    found.reject { |message| message.include?("name required") || message.include?("street and city") }.each do |message|
      next if message.include?("EIN") && ein.blank?
      next if message.include?("ZIP") && state.blank? && zip.blank?

      errors.add(:base, message)
    end
    if contact_phone.present? && !contact_phone.gsub(/\D/, "").match?(/\A\d{10}\z/)
      errors.add(:contact_phone, "must contain 10 digits")
    end
    if contact_email.present? && !validator.valid_contact_email?(contact_email)
      errors.add(:contact_email, "must follow SSA email formatting rules (at most 40 ASCII characters)")
    end
  end

  def missing_fields
    (FIELDS - [ :address_line2 ]).select { |field| public_send(field).blank? }
  end
end
