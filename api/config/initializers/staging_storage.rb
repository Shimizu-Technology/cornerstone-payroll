# frozen_string_literal: true

require "active_storage/service/s3_service"

module StagingStorageGuard
  def initialize(bucket:, **options)
    if StagingOutboundPolicy.staging?
      if options[:credentials] || options[:access_key_id].to_s.empty? || options[:secret_access_key].to_s.empty?
        raise StagingOutboundPolicy::ConfigurationError, "Staging storage requires explicit ACCESS_KEY_ID / SECRET_ACCESS_KEY"
      end
      StagingStoragePolicy.validate!(bucket: bucket, access_key: options[:access_key_id], secret_access_key: options[:secret_access_key], endpoint: options[:endpoint], region: options[:region])
      options[:endpoint] ||= ENV.fetch("STAGING_STORAGE_ENDPOINT")
    end
    super
    validate_staging_storage!
  end

  %i[upload download download_chunk delete delete_prefixed exist? compose update_metadata headers_for_direct_upload].each do |operation|
    define_method(operation) do |*args, **kwargs, &block|
      validate_staging_storage!
      super(*args, **kwargs, &block)
    end
  end

  %i[url url_for_direct_upload private_url public_url].each do |operation|
    define_method(operation) do |*args, **kwargs, &block|
      validate_staging_storage!
      StagingStoragePolicy.block_urls!
      super(*args, **kwargs, &block)
    end
  end

  private :private_url, :public_url

  private

  def validate_staging_storage!
    return unless StagingOutboundPolicy.staging?

    StagingStoragePolicy.validate!
    config = client.client.config
    StagingStoragePolicy.validate!(bucket: bucket.name, access_key: config.credentials.credentials.access_key_id, secret_access_key: config.credentials.credentials.secret_access_key, endpoint: config.endpoint.to_s.delete_suffix("/"), region: config.region)
  end
end
ActiveStorage::Service::S3Service.prepend(StagingStorageGuard)

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
