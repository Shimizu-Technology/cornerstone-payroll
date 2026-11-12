# frozen_string_literal: true

class PortalNotificationPreference < ApplicationRecord
  MODES = %w[immediate digest off].freeze

  belongs_to :user

  validates :category, inclusion: { in: PortalNotifications::CATEGORIES.keys }, uniqueness: { scope: :user_id }
  validates :delivery_mode, inclusion: { in: MODES }
end
