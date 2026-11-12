# frozen_string_literal: true

# One email ledger row per event and recipient. Provider acceptance is recorded
# as "sent"; it is not proof the person read the email or the portal item.
class PortalNotificationDelivery < ApplicationRecord
  STATUSES = %w[pending sent failed skipped].freeze
  DELIVERY_MODES = %w[immediate digest].freeze
  SKIP_REASONS = %w[no_recipients preference_off coalesced already_read recipient_removed access_revoked resource_unavailable
    email_delivery_disabled email_not_configured staging_contained].freeze

  belongs_to :portal_notification_event
  belongs_to :user, optional: true
  belongs_to :company

  validates :channel, inclusion: { in: %w[email] }
  validates :status, inclusion: { in: STATUSES }
  validates :delivery_mode, inclusion: { in: DELIVERY_MODES }
  validates :skip_reason, inclusion: { in: SKIP_REASONS }, allow_nil: true

  scope :pending, -> { where(status: "pending") }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def event
    portal_notification_event
  end

  def address
    user ? user.email : recipient_email
  end
end
