# frozen_string_literal: true

class User < ApplicationRecord
  belongs_to :company
  has_many :user_sessions, dependent: :destroy
  has_many :audit_logs, dependent: :nullify
  has_many :user_invitations, foreign_key: :invited_by_id, dependent: :nullify

  enum :role, { admin: 0, manager: 1, employee: 2 }

  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :name, presence: true
  validates :role, presence: true

  scope :active, -> { where(active: true) }
end
