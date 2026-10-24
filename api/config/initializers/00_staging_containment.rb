# frozen_string_literal: true

require Rails.root.join("lib/staging_outbound_policy")
StagingOutboundPolicy.validate!

module StagingHttpGuard
  def request(request, *args, &block)
    StagingOutboundPolicy.http_request!(self, request)
    super
  end

  private

  def connect
    StagingOutboundPolicy.http_host!(address, port, use_ssl?)
    super
  end
end
Net::HTTP.prepend(StagingHttpGuard)

# Includes presigning/direct uploads as well as ordinary object operations.
require "active_storage/service/s3_service"
module StagingStorageGuard
  def initialize(bucket:, **options)
    StagingOutboundPolicy.validate_storage!(bucket: bucket, access_key: options[:access_key_id])
    super
  end
end
ActiveStorage::Service::S3Service.prepend(StagingStorageGuard)
