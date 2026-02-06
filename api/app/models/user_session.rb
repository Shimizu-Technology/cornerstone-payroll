# frozen_string_literal: true

class UserSession < ApplicationRecord
  belongs_to :user

  encrypts :workos_access_token

  validates :jti, presence: true, uniqueness: true
  validates :expires_at, presence: true

  scope :active, -> { where(revoked_at: nil).where("expires_at > ?", Time.current) }

  def revoke!
    update!(revoked_at: Time.current)
  end
end
