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
    # Thirty 25 MiB photos need 15 batches and up to 30 individual retries
    # after validation rejection. Sixty permits those 45 plus 15 corrections.
    return if count <= 60

    response.set_header("Retry-After", "60")
    render json: { error: "You have uploaded too often. Please wait a minute and try again." }, status: :too_many_requests
  end
end
