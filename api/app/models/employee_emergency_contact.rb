# frozen_string_literal: true

class EmployeeEmergencyContact < ApplicationRecord
  FIELDS = %i[name relationship phone].freeze

  belongs_to :company
  belongs_to :employee

  validates :name, presence: true, length: { maximum: 120 }
  validates :relationship, length: { maximum: 120 }
  validates :name, :relationship, format: { without: /\x00/ }
  validates :phone, presence: true
  validate :normalize_phone

  scope :active, -> { where(deleted_at: nil) }

  def as_profile_json
    slice(*FIELDS).merge(id: id.to_s)
  end

  private

  def normalize_phone
    normalized, error = EmployeeContactValidator.normalize_phone(phone)
    if error
      errors.add(:phone, error)
    else
      self.phone = normalized
    end
  end
end
