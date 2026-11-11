# frozen_string_literal: true

module ClientDocumentUploadRateLimit
  extend ActiveSupport::Concern

  included do
    before_action :check_document_upload_rate!, only: :create
  end

  private

  def check_document_upload_rate!
    # Authentication has already resolved the trusted user here. Rack::Attack's
    # middleware cannot safely key on the unverified Authorization header.
    count = Rack::Attack.cache.count("portal-document-uploads/user/#{current_user.id}", 1.minute)
    return if count <= 20

    response.set_header("Retry-After", "60")
    render json: { error: "You have uploaded too often. Please wait a minute and try again." }, status: :too_many_requests
  end
end
