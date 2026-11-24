# frozen_string_literal: true

class EmployeePlaceholderEmail < ApplicationRecord
  MAX_REASON_LENGTH = 500
  # Advisory lock namespace for "placeholder marks of one organization".
  ORGANIZATION_LOCK = 450_301

  # Serializes marking and unmarking with history approvals that read the
  # marks, per organization. Held until the surrounding transaction commits.
  def self.lock_organization!(organization_id, shared: false)
    sql = shared ? "SELECT pg_advisory_xact_lock_shared(?, ?)" : "SELECT pg_advisory_xact_lock(?, ?)"
    connection.select_value(sanitize_sql_array([ sql, ORGANIZATION_LOCK, Integer(organization_id) ]))
  end

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
