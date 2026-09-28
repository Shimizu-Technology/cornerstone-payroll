# frozen_string_literal: true

class ExpenseArtifact < ApplicationRecord
  belongs_to :organization
  belongs_to :expense
  belongs_to :created_by, class_name: "User", optional: true

  validates :storage_key, :filename, :content_type, :sha256, presence: true
  validates :byte_size, numericality: { greater_than: 0 }
  validate :expense_belongs_to_organization

  private

  def expense_belongs_to_organization
    return if expense.blank? || organization_id.blank? || expense.organization_id == organization_id

    errors.add(:expense, "must belong to the same organization")
  end
end
