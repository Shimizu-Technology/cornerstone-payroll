# frozen_string_literal: true

module ClientPortalThreadActions
  extend ActiveSupport::Concern

  included do
    before_action :set_portal_thread, only: [ :show, :update, :mark_read ]
  end

  def index
    threads = ClientPortalThread.where(company_id: current_company_id)
                                .includes(:created_by, :resolved_by, messages: [ :author, { client_document: [ :employee, :uploaded_by ] } ])
                                .recent_first
    threads = threads.where(status: params[:status]) if params[:status].present?

    render json: {
      data: threads.map { |thread| portal_serializer.thread(thread) }
    }
  end

  def show
    @thread.mark_read_for!(current_user)
    render json: { data: portal_serializer.thread(@thread, include_messages: true) }
  end

  def create
    created_thread = nil
    initial_message = nil

    ClientPortalThread.transaction do
      created_thread = ClientPortalThread.create!(
        company_id: current_company_id,
        created_by: current_user,
        subject: params[:subject].presence || default_thread_subject
      )
      initial_message = create_message_for_thread!(created_thread) if params[:body].present? || params[:document_id].present?
    end

    record_audit!("client_portal_threads#create", created_thread, { subject: created_thread.subject })
    record_audit!("client_portal_messages#create", initial_message, { thread_id: created_thread.id }) if initial_message
    ClientPortalThreadChannel.broadcast_thread(created_thread, event: "thread_created")

    render json: { data: portal_serializer.thread(created_thread, include_messages: true) }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
  end

  def update
    attrs = {}
    if params[:status].present?
      attrs[:status] = params[:status]
      if params[:status] == "resolved"
        attrs[:resolved_at] = Time.current
        attrs[:resolved_by] = current_user
      elsif params[:status] == "open"
        attrs[:resolved_at] = nil
        attrs[:resolved_by] = nil
      end
    end
    attrs[:subject] = params[:subject] if params[:subject].present?

    @thread.update!(attrs)
    record_audit!("client_portal_threads#update", @thread, attrs.slice(:status, :subject))
    ClientPortalThreadChannel.broadcast_thread(@thread, event: "thread_updated")

    render json: { data: portal_serializer.thread(@thread, include_messages: true) }
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
  end

  def mark_read
    @thread.mark_read_for!(current_user)
    render json: { data: portal_serializer.thread(@thread) }
  end

  private

  def set_portal_thread
    @thread = ClientPortalThread.find_by!(id: params[:id], company_id: current_company_id)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Thread not found" }, status: :not_found
  end

  def create_message_for_thread!(target_thread)
    document = find_message_document
    ClientPortalMessage.create!(
      client_portal_thread: target_thread,
      company_id: current_company_id,
      author: current_user,
      body: params[:body],
      client_document: document
    )
  end

  def find_message_document
    return nil if params[:document_id].blank?

    ClientDocument.client_visible.find_by!(id: params[:document_id], company_id: current_company_id)
  rescue ActiveRecord::RecordNotFound
    raise ActiveRecord::RecordInvalid.new(ClientPortalMessage.new.tap { |message| message.errors.add(:client_document, "not found") })
  end

  def portal_serializer
    @portal_serializer ||= ClientPortalThreadSerializer.new(current_user: current_user)
  end

  def default_thread_subject
    "Portal message"
  end

  def record_audit!(action, record, metadata)
    AuditLog.record!(
      user: current_user,
      company_id: current_company_id,
      action: action,
      record_type: record.class.table_name,
      record_id: record.id,
      metadata: metadata,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end
end
