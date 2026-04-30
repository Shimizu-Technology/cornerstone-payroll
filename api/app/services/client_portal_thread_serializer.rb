# frozen_string_literal: true

class ClientPortalThreadSerializer
  def initialize(current_user:)
    @current_user = current_user
  end

  def thread(thread, include_messages: false)
    payload = {
      id: thread.id,
      company_id: thread.company_id,
      subject: thread.subject,
      status: thread.status,
      created_by_id: thread.created_by_id,
      created_by_name: thread.created_by&.name,
      resolved_by_id: thread.resolved_by_id,
      resolved_by_name: thread.resolved_by&.name,
      resolved_at: thread.resolved_at,
      last_message_at: thread.last_message_at,
      unread: thread.unread_for?(@current_user),
      created_at: thread.created_at,
      updated_at: thread.updated_at,
      latest_message: thread.messages.loaded? ? message(thread.messages.max_by(&:created_at)) : message(thread.messages.order(created_at: :desc, id: :desc).first)
    }

    if include_messages
      payload[:messages] = thread.messages.chronological.includes(:author, client_document: [ :employee, :uploaded_by ]).map { |msg| message(msg) }
    end

    payload
  end

  def message(message)
    return nil unless message

    {
      id: message.id,
      thread_id: message.client_portal_thread_id,
      body: message.body,
      author_id: message.author_id,
      author_name: message.author&.name,
      author_role: message.author&.role,
      created_at: message.created_at,
      document: document(message.client_document)
    }
  end

  def document(document)
    return nil unless document

    {
      id: document.id,
      title: document.title,
      category: document.category,
      file_name: document.file_name,
      content_type: document.content_type,
      file_size: document.file_size,
      notes: document.notes,
      employee_id: document.employee_id,
      employee_name: document.employee&.full_name,
      uploaded_by_id: document.uploaded_by_id,
      uploaded_by_name: document.uploaded_by&.name,
      visible_to_client: document.visible_to_client,
      shared_by_staff: document.shared_by_staff,
      created_at: document.created_at,
      preview_status: document.preview_status,
      preview_available: document.preview_available?,
      preview_generated_at: document.preview_generated_at,
      preview_content_type: document.preview_content_type,
      preview_error: document.preview_error
    }
  end
end
