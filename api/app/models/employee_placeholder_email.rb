# frozen_string_literal: true

class EmployeePlaceholderEmail < ApplicationRecord
  MAX_REASON_LENGTH = 500

  belongs_to :organization
  belongs_to :marked_by, class_name: "User", optional: true

  before_validation :normalize_email

  validates :email, presence: true, uniqueness: { scope: :organization_id, case_sensitive: false }
  validates :reason, length: { maximum: MAX_REASON_LENGTH }, allow_nil: true

  private

  def normalize_email
    self.email = EmployeeContactValidator.normalize_email(email)
  end
end
