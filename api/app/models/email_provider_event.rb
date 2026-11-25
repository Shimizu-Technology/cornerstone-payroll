# frozen_string_literal: true

# One verified email provider webhook event (M4-5), kept before the webhook
# answers 2xx. It names no company and no address; it is matched to an
# EmployeeDocumentNotice by provider_message_id when that notice records the
# id, which can be after the event arrives (a fast bounce).
# EmployeeDocuments::NoticeDeliveryEvent applies it; applied_at marks it done.
class EmailProviderEvent < ApplicationRecord
  DELIVERY_STATUSES = %w[delivered delayed bounced complained].freeze
  # Events that matched nothing are kept this long, then pruned by the sweep.
  RETENTION = 90.days

  validates :provider, :event_id, :event_type, :occurred_at, presence: true
  validates :delivery_status, inclusion: { in: DELIVERY_STATUSES }, allow_nil: true

  scope :unapplied, -> { where(applied_at: nil).where.not(delivery_status: nil) }
end
