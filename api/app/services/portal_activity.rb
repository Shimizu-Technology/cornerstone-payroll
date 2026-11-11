# frozen_string_literal: true

# One vocabulary and deliberately small public projection for both audiences.
class PortalActivity
  DOCUMENT_ACTIONS = %w[client_documents#create admin_client_documents#create client_documents#destroy admin_client_documents#destroy portal_documents#opened portal_documents#preview portal_documents#download client_documents#archive admin_client_documents#archive admin_client_documents#unarchive].freeze
  THREAD_ACTIONS = %w[client_portal_threads#create client_portal_threads#update client_portal_threads#resolved client_portal_threads#reopened client_portal_threads#opened client_portal_threads#mark_read client_portal_messages#create].freeze

  def self.document_metadata(document)
    {
      title: document.title,
      category: document.category, employee_id: document.employee_id,
      employee_name: document.employee&.full_name, visible_to_client: document.visible_to_client
    }
  end

  def self.message_metadata(message)
    {
      thread_id: message.client_portal_thread_id, subject: message.client_portal_thread.subject,
      document_id: message.client_document_id, attachment_ids: [ message.client_document_id ].compact,
      attachment_titles: [ message.client_document&.title ].compact,
      employee_name: message.client_document&.employee&.full_name
    }
  end

  def self.record!(user:, record:, action:, metadata: {}, **context)
    subject = record.is_a?(ClientPortalMessage) ? record.client_portal_thread.subject : AuditRecordSnapshot.subject_name(record)
    AuditLog.record!(user: user, company_id: record.company_id, action: action,
      record_type: record.class.table_name, record_id: record.id,
      subject_name: subject, metadata: metadata, **context)
  end

  def self.feed(resource)
    scope = AuditLog.where(company_id: resource.company_id)
    scope = if resource.is_a?(ClientDocument)
      scope.where(record_type: "client_documents", record_id: resource.id, action: DOCUMENT_ACTIONS)
    else
      scope.where(action: THREAD_ACTIONS).where(
        "(record_type = 'client_portal_threads' AND record_id = :id) OR (record_type = 'client_portal_messages' AND metadata->>'thread_id' = :text_id)",
        id: resource.id, text_id: resource.id.to_s)
    end
    scope.where(event_category: %w[activity document_access]).newest_first
  end

  def self.serialize(log)
    {
      id: log.id, actor_name: log.actor_name.presence || "System",
      action: log.action, subject_name: log.subject_name,
      headline: AuditLogPresenter.new(log).headline, created_at: log.created_at
    }
  end
end
