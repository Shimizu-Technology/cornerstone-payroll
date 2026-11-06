# frozen_string_literal: true

require Rails.root.join("lib/active_storage/service/staging_s3_service")

# Framework blob redirects, proxy and disk routes bypass ApplicationController.
# Fail before resolving a signed ID or accepting a direct-upload blob record.
Rails.application.config.to_prepare do
  ActiveStorage::BaseController.before_action(prepend: true) do
    if StagingOutboundPolicy.staging?
      render json: { error: "#{StagingOutboundPolicy::LABEL}: raw storage delivery and direct uploads are disabled", staging: true }, status: :service_unavailable
    end
  end
end

module StagingBlobUrlGuard
  def url(...)
    StagingStoragePolicy.block_urls!
    super
  end

  def service_url_for_direct_upload(...)
    StagingStoragePolicy.block_urls!
    super
  end
end
ActiveSupport.on_load(:active_storage_blob) { prepend StagingBlobUrlGuard }

module StagingBlobKeyGeneration
  def generate_unique_secure_token(...)
    StagingStoragePolicy.new_key(super)
  end
end
ActiveSupport.on_load(:active_storage_blob) { singleton_class.prepend StagingBlobKeyGeneration }
