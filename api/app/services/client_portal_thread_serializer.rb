# frozen_string_literal: true

class ClientPortalThreadSerializer
  def initialize(current_user:)
    @current_user = current_user
  end

  def preload_reads(threads)
    @read_cursors = PortalThreadReadReceipt.where(user_id: @current_user.id, client_portal_thread_id: threads.map(&:id))
      .pluck(:client_portal_thread_id, :last_displayed_message_id).to_h
    @open_request_counts = PortalFileRequest.outstanding.where(client_portal_thread_id: threads.map(&:id))
      .group(:client_portal_thread_id).count
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
      unread: thread.unread_for?(@current_user, cursor: @read_cursors && [ thread.read_baseline_message_id, @read_cursors.fetch(thread.id, 0) ].max),
      created_at: thread.created_at,
      updated_at: thread.updated_at,
      latest_message: message(latest_message_for(thread, thread_messages)),
      open_file_request_count: open_file_request_count(thread)
    }

    if include_messages
      payload[:messages] = thread_messages.map { |msg| message(msg) }
      payload[:display_token] = PortalDisplayReceipt.issue(thread: thread, user: @current_user, messages: thread_messages) if @current_user
    end

    payload
  end

  def message(message)
    return nil unless message

    documents = message_documents(message).filter_map { |document| document(document) }
    {
      id: message.id,
      thread_id: message.client_portal_thread_id,
      kind: message.kind,
      body: message.body,
      author_id: message.author_id,
      author_name: message.author&.name || message.author_name_snapshot,
      author_role: message.author&.role,
      author_audience: message.author_audience,
      created_at: message.created_at,
      # The first file, for readers of the single-attachment shape.
      document: documents.first,
      documents: documents,
      file_request: file_request(message.file_request)
    }
  end

  def file_request(request)
    return nil unless request

    {
      id: request.id,
      thread_id: request.client_portal_thread_id,
      title: request.title,
      category: request.category,
      employee_id: request.employee_id,
      employee_name: request.employee&.full_name,
      payroll_submission_period_id: request.payroll_submission_period_id,
      payroll_submission_period_label: request.payroll_submission_period&.label,
      due_on: request.due_on,
      status: request.status,
      status_label: request.status_label,
      requested_by_name: request.requested_by&.name || request.requested_by_name_snapshot,
      request_message_id: request.request_message_id,
      last_response_message_id: request.last_response_message_id,
      responded_by_name: request.responded_by&.name,
      responded_at: request.responded_at,
      resolved_by_name: request.resolved_by&.name,
      resolved_at: request.resolved_at,
      created_at: request.created_at,
      lock_version: request.lock_version
    }
  end

  def document(document)
    return nil unless document
    return nil unless document.visible_to_client || @current_user&.staff_member?

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
      archived_at: document.archived_at,
      archived_by_id: document.archived_by_id,
      scan_status: document.scan_status,
      preview_status: document.preview_status,
      preview_available: document.preview_available?,
      preview_generated_at: document.preview_generated_at,
      preview_content_type: document.preview_content_type,
      preview_error: public_preview_error(document)
    }
  end

  private

  MESSAGE_INCLUDES = [ :author, { client_document: [ :employee, :uploaded_by ] },
    { attachments: { client_document: [ :employee, :uploaded_by ] } },
    { file_request: [ :employee, :requested_by, :responded_by, :resolved_by, :payroll_submission_period ] } ].freeze

  def messages_for_thread(thread)
    thread.messages.chronological.includes(*MESSAGE_INCLUDES).to_a
  end

  # Migrated messages have join rows; the legacy column covers any that
  # were written by an older release during a rolling deploy.
  def message_documents(message)
    attached = message.attachments.map(&:client_document)
    attached.presence || [ message.client_document ].compact
  end

  def open_file_request_count(thread)
    return @open_request_counts.fetch(thread.id, 0) if @open_request_counts

    thread.file_requests.outstanding.count
  end

  def latest_message_for(thread, thread_messages)
    return thread_messages.last if thread_messages

    if thread.messages.loaded?
      return thread.messages.max_by { |msg| [ msg.created_at || Time.zone.at(0), msg.id || 0 ] }
    end

    thread.messages.includes(*MESSAGE_INCLUDES).order(created_at: :desc, id: :desc).first
  end

  def public_preview_error(document)
    return nil unless document.preview_status == "failed"

    "Preview is unavailable for this file."
  end
end
