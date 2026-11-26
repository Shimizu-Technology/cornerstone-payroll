# frozen_string_literal: true

# A notice owed to an employee's previous email address
# (EmployeeLinks::EmailChange). Durable, so a queue outage can't lose it.
class EmployeeEmailChangeNotice < ApplicationRecord
  STATUSES = %w[pending sent skipped failed].freeze

  belongs_to :company
  belongs_to :employee

  validates :change_id, presence: true, uniqueness: true
  validates :recipient_email, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :attempts, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
