# frozen_string_literal: true

# Append-only database record written exclusively by the owner-only
# `convert_demo_company_to_flag(...)` SQL function and marked reverted
# exclusively by `revert_demo_company_to_legacy_shape(...)`.
#
# Stores the exact pre-conversion shape columns, employee-account-link
# environments, and post-conversion target shape so targeted rollback is bound
# strictly to a recorded conversion and cannot accept invented external metadata.
class DemoShapeConversion < ApplicationRecord
  belongs_to :organization
  belongs_to :company
  belongs_to :actor, class_name: "User"
  belongs_to :reverted_by, class_name: "User", optional: true

  scope :active, -> { where(reverted_at: nil) }

  def readonly?
    true
  end

  def reverted?
    reverted_at.present?
  end
end
