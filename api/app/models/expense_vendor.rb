# frozen_string_literal: true

class ExpenseVendor < ApplicationRecord
  belongs_to :organization
  has_many :expenses, dependent: :restrict_with_error

  validates :name, presence: true, uniqueness: { scope: :organization_id }, length: { maximum: 255 }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  scope :alphabetical, -> { order(:name, :id) }
end
