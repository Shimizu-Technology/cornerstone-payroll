# frozen_string_literal: true

# Shared by both namespaces. Requests are found within the selected company.
module PortalFileRequestActions
  extend ActiveSupport::Concern
  include ExplicitCompanyAccess

  included do
    rescue_from PortalFileRequests::Actions::Invalid do |error|
      render json: { error: error.message, details: error.details }, status: :unprocessable_entity
    end
    rescue_from PortalFileRequests::Actions::Conflict do |error|
      render json: { error: error.message }, status: :conflict
    end
    rescue_from ActiveRecord::RecordInvalid do |error|
      render json: { error: "Please check the details", details: error.record.errors.messages }, status: :unprocessable_entity
    end
    rescue_from ActiveRecord::RecordNotFound do |error|
      render json: { error: error.message }, status: :not_found
    end
  end

  private

  def set_file_request
    @file_request = PortalFileRequest.find_by(id: params[:id], company_id: current_company_id)
    render json: { error: "Request not found" }, status: :not_found unless @file_request
  end

  def file_request_actions
    @file_request_actions ||= PortalFileRequests::Actions.new(company: Company.find(current_company_id), actor: current_user,
      request_context: { ip_address: request.remote_ip, user_agent: request.user_agent })
  end

  def render_step(result)
    request, message, replayed = result
    skip_default_audit_log!
    render json: { data: serializer.file_request(request), message: serializer.message(message.reload) },
      status: replayed ? :ok : :created
  end

  def serializer
    @serializer ||= ClientPortalThreadSerializer.new(current_user: current_user)
  end

  def step_params
    params.permit(:body, :idempotency_key, :response_message_id, document_ids: [])
  end
end
