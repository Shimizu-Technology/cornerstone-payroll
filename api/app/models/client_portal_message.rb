# frozen_string_literal: true

class ClientPortalMessage < ApplicationRecord
  belongs_to :client_portal_thread, inverse_of: :messages
  belongs_to :company
  belongs_to :author, class_name: "User", optional: true
  belongs_to :client_document, optional: true

  validates :body, presence: true, unless: -> { client_document_id.present? }
  validate :thread_and_document_belong_to_company

  scope :chronological, -> { order(created_at: :asc, id: :asc) }

  after_create_commit :touch_thread_and_broadcast

  private

  def thread_and_document_belong_to_company
    if client_portal_thread&.company_id != company_id
      errors.add(:client_portal_thread, "must belong to the same company")
    end

    return unless client_document

    errors.add(:client_document, "must belong to the same company") if client_document.company_id != company_id
  end

  def touch_thread_and_broadcast
    timestamp = created_at || Time.current
    read_updates = if ClientPortalThread.staff_user?(author)
      { staff_last_read_at: timestamp }
    else
      { client_last_read_at: timestamp }
    end

    client_portal_thread.update!(
      read_updates.merge(
        last_message_at: timestamp,
        updated_at: Time.current
      )
    )

    ClientPortalThreadChannel.broadcast_thread(client_portal_thread, event: "message_created")
  end
end
