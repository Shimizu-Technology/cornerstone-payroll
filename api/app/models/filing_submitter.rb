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

  def missing_fields
    (FIELDS - [ :address_line2 ]).select { |field| public_send(field).blank? }
  end
end
