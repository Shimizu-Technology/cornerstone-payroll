# frozen_string_literal: true

# An explicit, attributed "reviewed" decision on one year-end judgment warning.
# It counts only while its digest matches the warning computed from current data.
class YearEndAcknowledgement < ApplicationRecord
  belongs_to :company
  belongs_to :acknowledged_by, class_name: "User", optional: true

  validates :tax_year,
            presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 2000, less_than_or_equal_to: 2200 }
  validates :warning_code, :warning_digest, :acknowledged_at, presence: true
  validates :acknowledged_by_name, :acknowledged_by_email, :acknowledged_by_role, presence: true
  validates :note, presence: true, length: { maximum: 2_000 }
  validates :warning_code, uniqueness: { scope: %i[company_id tax_year] }

  def payload
    {
      warning_code: warning_code,
      warning_digest: warning_digest,
      note: note,
      acknowledged_at: acknowledged_at&.iso8601,
      acknowledged_by: { id: acknowledged_by_id, name: acknowledged_by_name, role: acknowledged_by_role }
    }
  end
end
