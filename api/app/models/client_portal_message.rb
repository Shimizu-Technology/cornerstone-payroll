# frozen_string_literal: true

class ClientPortalMessage < ApplicationRecord
  belongs_to :client_portal_thread, inverse_of: :messages
  belongs_to :company
  belongs_to :author, class_name: "User", optional: true
  belongs_to :client_document, optional: true

  validates :body, presence: true, unless: -> { client_document_id.present? }
  validate :thread_and_document_belong_to_company
  around_save :protect_attachment_use

  scope :chronological, -> { order(created_at: :asc, id: :asc) }

  validates :idempotency_key, length: { maximum: 128 }, allow_nil: true
  after_create :touch_thread
  after_create_commit :broadcast_thread

  private

  def thread_and_document_belong_to_company
    if client_portal_thread&.company_id != company_id
      errors.add(:client_portal_thread, "must belong to the same company")
    end

    return unless client_document

    errors.add(:client_document, "must belong to the same company") if client_document.company_id != company_id
  end

  def protect_attachment_use
    return yield unless client_document && (new_record? || will_save_change_to_client_document_id?)

    client_document.with_lock do
      unless client_document.visible_to_client?
        errors.add(:client_document, "must be visible to the client")
        raise ActiveRecord::RecordInvalid.new(self)
      end
      client_document.ensure_usable_for!(:message_attachment)
      yield
    end
  rescue ClientDocumentScanner::Blocked => e
    errors.add(:client_document, e.message)
    raise ActiveRecord::RecordInvalid.new(self)
  end

  def touch_thread
    timestamp = created_at || Time.current
    # Legacy consumers retain side timestamps; personal receipts only follow display.
    read_updates = ClientPortalThread.staff_user?(author) ? { staff_last_read_at: timestamp } : { client_last_read_at: timestamp }
    client_portal_thread.update!(read_updates.merge(last_message_at: timestamp, updated_at: Time.current))
  end

  def broadcast_thread
    ClientPortalThreadChannel.broadcast_thread(client_portal_thread, event: "message_created")
  end
end
