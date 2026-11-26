# frozen_string_literal: true

class PortalNotificationPreference < ApplicationRecord
  MODES = %w[immediate digest off].freeze

  belongs_to :user

  MUTABLE_CATEGORIES = PortalNotifications::CATEGORIES.reject { |_key, category| category[:mandatory] }.keys.freeze

  validates :category, inclusion: { in: MUTABLE_CATEGORIES }, uniqueness: { scope: :user_id }
  validates :delivery_mode, inclusion: { in: MODES }
end
