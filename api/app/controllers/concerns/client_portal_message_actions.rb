# frozen_string_literal: true

module ClientPortalMessageActions
  extend ActiveSupport::Concern
  include ExplicitCompanyAccess
  include PortalAccessTracking

  included do
    before_action :set_portal_thread
  end

  def create
    key = params[:idempotency_key].presence
    message = nil
    replayed = false
    @thread.with_lock do
      message = @thread.messages.find_by(author_id: current_user.id, idempotency_key: key) if key
      if message
        unless message.body.to_s == params[:body].to_s && message.client_document_id == params[:document_id].presence&.to_i
          return render json: { error: "This retry key was used for a different message" }, status: :conflict
        end
        replayed = true
      else
        message = ClientPortalMessage.create!(
          client_portal_thread: @thread, company_id: current_company_id,
          author: current_user, body: params[:body], client_document: document, idempotency_key: key)
        PortalActivity.record!(user: current_user, record: message, action: "client_portal_messages#create",
          metadata: PortalActivity.message_metadata(message),
          ip_address: request.remote_ip, user_agent: request.user_agent)
        PortalNotifications.message_created!(message)
      end
    end
    skip_default_audit_log!
    render json: { data: ClientPortalThreadSerializer.new(current_user: current_user).message(message) }, status: replayed ? :ok : :created
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
