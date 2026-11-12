# frozen_string_literal: true

module ClientPortalMessageActions
  extend ActiveSupport::Concern
  include ExplicitCompanyAccess
  include PortalAccessTracking

  included do
    before_action :set_portal_thread
  end

  # Text plus up to ten files, saved together. A retry with the same key
  # returns the saved message instead of sending it twice.
  def create
    key = params[:idempotency_key].presence
    message = nil
    replayed = false
    documents = PortalMessages::Attachments.resolve!(company_id: current_company_id, user: current_user,
      ids: PortalMessages::Attachments.requested_ids(params))
    @thread.with_lock do
      message = @thread.messages.find_by(author_id: current_user.id, idempotency_key: key) if key
      if message
        unless message.kind == "message" && message.body.to_s == params[:body].to_s && message.attachment_ids == documents.map(&:id)
          return render json: { error: "This retry key was used for a different message" }, status: :conflict
        end
        replayed = true
      else
        message = ClientPortalMessage.create!(
          client_portal_thread: @thread, company_id: current_company_id,
          author: current_user, body: params[:body], attach_documents: documents, idempotency_key: key)
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
end
