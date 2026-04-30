# frozen_string_literal: true

class ClientPortalThreadSerializer
  def initialize(current_user:)
    @current_user = current_user
  end

  def thread(thread, include_messages: false)
    thread_messages = include_messages ? messages_for_thread(thread) : nil

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
      latest_message: message(latest_message_for(thread, thread_messages))
    }

    payload[:messages] = thread_messages.map { |msg| message(msg) } if include_messages

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
      preview_error: public_preview_error(document)
    }
  end

  private

  def messages_for_thread(thread)
    thread.messages.chronological.includes(:author, client_document: [ :employee, :uploaded_by ]).to_a
  end

  def latest_message_for(thread, thread_messages)
    return thread_messages.last if thread_messages

    if thread.messages.loaded?
      return thread.messages.max_by { |msg| [ msg.created_at || Time.zone.at(0), msg.id || 0 ] }
    end

    thread.messages.includes(:author, client_document: [ :employee, :uploaded_by ]).order(created_at: :desc, id: :desc).first
  end

  def public_preview_error(document)
    return nil unless document.preview_status == "failed"

    "Preview is unavailable for this file."
  end
end
