# frozen_string_literal: true

# A typed portal event, saved in the same transaction as the domain change.
# Metadata holds record IDs and counts only; never names, bodies or file titles.
class PortalNotificationEvent < ApplicationRecord
  RECIPIENT_STATUSES = %w[recipients no_recipients actor_only].freeze
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
  scope :without_staff_recipients, -> {
    where(recipient_status: "no_recipients", category: STAFF_CATEGORIES)
      .where("metadata->>'recipient_scope' IS DISTINCT FROM ?", "super_admins")
  }

  def audience
    PortalNotifications::CATEGORIES.fetch(category).fetch(:audience)
  end

  def message_event?
    PortalNotifications::EVENT_TYPES.fetch(event_type)[:message]
  end

  def override_decision?
    event_type == "payroll_review_decided" && metadata["decision"].in?(%w[cornerstone_override self_override])
  end

  def super_admin_alert?
    metadata["recipient_scope"] == "super_admins"
  end

  def preference_category
    super_admin_alert? ? "payroll_super_admin" : category
  end

  def client_viewers_only?
    metadata["recipient_scope"] == "client_viewers"
  end

  def exclude_actor_address?
    override_decision? || event_type.in?(%w[payroll_committed payroll_reopened employee_change_submitted
      address_approval_requested employee_contact_changed
      employee_contact_confirmation_requested w2_ready_to_post])
  end

  def client_managers_only?
    PortalNotifications::EVENT_TYPES.fetch(event_type)[:client_managers_only] == true ||
      metadata["recipient_scope"] == "client_managers"
  end
end
