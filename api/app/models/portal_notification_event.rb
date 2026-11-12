# frozen_string_literal: true

# A typed portal event, saved in the same transaction as the domain change.
# Metadata holds record IDs and counts only; never names, bodies or file titles.
class PortalNotificationEvent < ApplicationRecord
  RECIPIENT_STATUSES = %w[recipients no_recipients].freeze
  STAFF_CATEGORIES = PortalNotifications::CATEGORIES.select { |_key, category| category[:audience] == "staff" }.keys.freeze

  belongs_to :organization
  belongs_to :company
  belongs_to :actor, class_name: "User", optional: true
  belongs_to :subject, polymorphic: true, optional: true
  has_many :deliveries, class_name: "PortalNotificationDelivery", dependent: :delete_all

  validates :event_type, inclusion: { in: PortalNotifications::EVENT_TYPES.keys }
  validates :category, inclusion: { in: PortalNotifications::CATEGORIES.keys }
  validates :recipient_status, inclusion: { in: RECIPIENT_STATUSES }
  validates :dedupe_key, presence: true

  # Client work that nobody on staff was set up to hear about.
  scope :without_staff_recipients, -> { where(recipient_status: "no_recipients", category: STAFF_CATEGORIES) }

  def audience
    PortalNotifications::CATEGORIES.fetch(category).fetch(:audience)
  end

  def message_event?
    PortalNotifications::EVENT_TYPES.fetch(event_type)[:message]
  end
end
