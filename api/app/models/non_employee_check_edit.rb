# frozen_string_literal: true

# Audit-log entry for a single edit applied to a NonEmployeeCheck. Stores a
# before/after snapshot of just the fields that actually changed plus optional
# user-supplied context. Records are immutable once written.
class NonEmployeeCheckEdit < ApplicationRecord
  self.inheritance_column = nil

  belongs_to :non_employee_check
  belongs_to :edited_by, class_name: "User", optional: true

  validates :before, presence: true
  validates :after, presence: true
  validates :changed_fields, presence: true

  # Audit rows must never be mutated; once written they're history.
  def readonly?
    persisted?
  end

  def edited_by_name
    edited_by&.name.presence || edited_by&.email
  end
end
