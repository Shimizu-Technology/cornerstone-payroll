# frozen_string_literal: true

class CableConnectionTicket < ApplicationRecord
  belongs_to :user
  belongs_to :company

  validates :token_digest, :expires_at, presence: true
  validates :token_digest, uniqueness: true

  scope :active, -> { where(used_at: nil).where("expires_at > ?", Time.current) }
  scope :stale, -> { where("expires_at <= :now OR used_at IS NOT NULL", now: Time.current) }
end
