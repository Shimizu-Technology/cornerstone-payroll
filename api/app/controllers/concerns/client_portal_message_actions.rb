# frozen_string_literal: true

module ClientPortalMessageActions
  extend ActiveSupport::Concern

  included do
    before_action :set_portal_thread
  end

  def create
    message = ClientPortalMessage.create!(
      client_portal_thread: @thread,
      company_id: current_company_id,
      author: current_user,
      body: params[:body],
      client_document: document
    )

    AuditLog.record!(
      user: current_user,
      company_id: current_company_id,
      action: "client_portal_messages#create",
      record_type: "client_portal_messages",
      record_id: message.id,
      metadata: { thread_id: @thread.id, document_id: message.client_document_id },
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )

    render json: {
      data: ClientPortalThreadSerializer.new(current_user: current_user).message(message)
    }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
  end

  private

  def set_portal_thread
    @thread = ClientPortalThread.find_by!(id: params[:portal_thread_id], company_id: current_company_id)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Thread not found" }, status: :not_found
  end

  def document
    return nil if params[:document_id].blank?

    @document ||= ClientDocument.client_visible.find_by!(id: params[:document_id], company_id: current_company_id)
  rescue ActiveRecord::RecordNotFound
    raise ActiveRecord::RecordInvalid.new(ClientPortalMessage.new.tap { |message| message.errors.add(:client_document, "not found") })
  end
end
