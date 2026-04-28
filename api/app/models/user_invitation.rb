# frozen_string_literal: true

class UserInvitation < ApplicationRecord
  belongs_to :company
  belongs_to :invited_by, class_name: "User", optional: true

  enum :role, { admin: 0, manager: 1, employee: 2, accountant: 3, client: 4 }

  validates :email, presence: true
  validates :token, presence: true, uniqueness: true
  validates :invited_by, presence: true, on: :create
  validates :invited_at, presence: true
  validates :expires_at, presence: true

  scope :active, -> { where(accepted_at: nil).where("expires_at > ?", Time.current) }

  def accept!
    update!(accepted_at: Time.current)
  end
end
