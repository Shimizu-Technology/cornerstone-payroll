# frozen_string_literal: true

require "active_storage/service/s3_service"

class ActiveStorage::Service::StagingS3Service < ActiveStorage::Service::S3Service
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

  %i[download download_chunk exist?].each do |operation|
    define_method(operation) do |*args, **kwargs, &block|
      validate_staging_storage!
      super(*args, **kwargs, &block)
    end
  end

  def upload(key, ...)
    validate_staging_storage!
    StagingStoragePolicy.write!(key)
    super
  end

  def compose(source_keys, destination_key, ...)
    validate_staging_storage!
    StagingStoragePolicy.write!(destination_key)
    super
  end

  def update_metadata(key, ...)
    validate_staging_storage!
    StagingStoragePolicy.write!(key)
    super
  end

  %i[delete].each do |operation|
    define_method(operation) do |key|
      validate_staging_storage!
      return unless StagingStoragePolicy.delete_allowed?(key)
      super(key)
    end
  end

  def delete_prefixed(prefix)
    validate_staging_storage!
    return unless StagingStoragePolicy.delete_allowed?(prefix)
    return super unless StagingStoragePolicy.shared?

    # Bucket-root bulk deletion cannot prove its keys at the HTTP boundary.
    # Recheck every listed destination and issue guarded individual deletes.
    bucket.objects(prefix: prefix).each { |object| delete(object.key) }
  end

  def headers_for_direct_upload(...)
    validate_staging_storage!
    StagingStoragePolicy.block_urls!
    super
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
