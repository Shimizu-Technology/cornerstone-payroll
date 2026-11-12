# frozen_string_literal: true

class ClientPortalMessage < ApplicationRecord
  include PortalInboxUpdates
  MAX_ATTACHMENTS = 10
  KINDS = %w[message file_request file_response file_request_accepted file_request_asked_again file_request_withdrawn].freeze

  attr_readonly :author_audience, :author_name_snapshot, :kind, :portal_file_request_id
  before_validation :snapshot_author_origin, on: :create
  validates :author_audience, inclusion: { in: %w[client staff unknown] }
  validates :kind, inclusion: { in: KINDS }
  belongs_to :client_portal_thread, inverse_of: :messages
  belongs_to :company
  belongs_to :author, class_name: "User", optional: true
  # The first attachment, kept for readers of the single-file API.
  belongs_to :client_document, optional: true
  belongs_to :file_request, class_name: "PortalFileRequest", foreign_key: :portal_file_request_id, optional: true, inverse_of: :messages
  has_many :attachments, -> { order(:position, :id) }, class_name: "PortalMessageAttachment",
    inverse_of: :client_portal_message, dependent: :delete_all
  has_many :documents, through: :attachments, source: :client_document

  validates :body, presence: true, if: -> { kind == "message" && attachment_documents.empty? }
  validates :body, length: { maximum: 5000 }
  validate :thread_and_documents_belong_to_company
  validate :attachment_count
  validate :typed_messages_have_request
  around_create :protect_attachment_use

  scope :chronological, -> { order(created_at: :asc, id: :asc) }

  validates :idempotency_key, length: { maximum: 128 }, allow_nil: true
  after_create :touch_thread
  after_create_commit :broadcast_thread

  # Files to attach on create, in order. Defaults to the legacy single file.
  def attach_documents=(documents)
    @attach_documents = Array(documents).compact.uniq(&:id)
    self.client_document = @attach_documents.first
  end

  def attachment_documents
    return attachments.map(&:client_document) if persisted?

    @attach_documents || [ client_document ].compact
  end

  def attachment_ids
    persisted? ? attachments.map(&:client_document_id) : attachment_documents.map(&:id)
  end

  # True when this message reopened a resolved conversation.
  def reopened_thread?
    @reopened_thread == true
  end

  private

  def snapshot_author_origin
    self.author_audience = author&.client? ? "client" : author&.staff_member? ? "staff" : "unknown"
    self.author_name_snapshot = author&.name
  end

  def thread_and_documents_belong_to_company
    if client_portal_thread&.company_id != company_id
      errors.add(:client_portal_thread, "must belong to the same company")
    end

    return if attachment_documents.all? { |document| document.company_id == company_id }

    errors.add(:client_document, "must belong to the same company")
  end

  def attachment_count
    return if attachment_documents.size <= MAX_ATTACHMENTS

    errors.add(:base, "Attach no more than #{MAX_ATTACHMENTS} files to one message")
  end

  def typed_messages_have_request
    return if (kind == "message") == portal_file_request_id.nil?

    errors.add(:kind, "does not match the file request")
  end

  # Each file is locked in id order and rechecked, so a file archived or made
  # staff-only by someone else cannot be attached in the same instant.
  def protect_attachment_use
    documents = attachment_documents
    return yield if documents.empty?

    locked = ClientDocument.where(id: documents.map(&:id)).order(:id).lock.to_a.index_by(&:id)
    documents.each do |document|
      current = locked[document.id]
      unless current && current.company_id == company_id
        errors.add(:client_document, "not found")
        raise ActiveRecord::RecordInvalid.new(self)
      end
      unless current.visible_to_client?
        errors.add(:client_document, "must be visible to the client")
        raise ActiveRecord::RecordInvalid.new(self)
      end
      current.ensure_usable_for!(:message_attachment)
    end
    yield
    # Saved outside the association so autosave never re-saves them.
    documents.each_with_index do |document, position|
      PortalMessageAttachment.create!(company_id: company_id, client_portal_message: self, client_document_id: document.id, position: position)
    end
    attachments.reset
  rescue ClientDocumentScanner::Blocked => e
    errors.add(:client_document, e.message)
    raise ActiveRecord::RecordInvalid.new(self)
  end

  # A reply to a resolved conversation reopens it in the same transaction.
  def touch_thread
    timestamp = created_at || Time.current
    # Legacy consumers retain side timestamps; personal receipts only follow display.
    read_updates = ClientPortalThread.staff_user?(author) ? { staff_last_read_at: timestamp } : { client_last_read_at: timestamp }
    updates = read_updates.merge(last_message_at: timestamp, updated_at: Time.current)
    if client_portal_thread.resolved?
      updates.merge!(status: "open", resolved_at: nil, resolved_by: nil)
      @reopened_thread = true
    end
    client_portal_thread.update!(updates)
    return unless @reopened_thread

    PortalActivity.record!(user: author, record: client_portal_thread, action: "client_portal_threads#reopened",
      metadata: { subject: client_portal_thread.subject, reason: "reply", message_id: id })
  end

  def broadcast_thread
    ClientPortalThreadChannel.broadcast_thread(client_portal_thread, event: "message_created")
  end
end
