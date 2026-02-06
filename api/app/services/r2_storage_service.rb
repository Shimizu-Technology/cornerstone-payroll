# frozen_string_literal: true

require "aws-sdk-s3"

# Cloudflare R2 Storage Service
#
# R2 is S3-compatible, so we use the AWS SDK with custom endpoint.
#
# Required ENV vars:
#   R2_ACCOUNT_ID
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_BUCKET
#   R2_PUBLIC_URL (optional, for public access)
#
# Usage:
#   service = R2StorageService.new
#
#   # Upload
#   url = service.upload("paystubs/emp_1_2026-02-05.pdf", pdf_binary)
#
#   # Download
#   data = service.download("paystubs/emp_1_2026-02-05.pdf")
#
#   # Signed URL (for temporary access)
#   url = service.signed_url("paystubs/emp_1_2026-02-05.pdf", expires_in: 1.hour)
#
class R2StorageService
  class ConfigurationError < StandardError; end
  class UploadError < StandardError; end
  class DownloadError < StandardError; end

  def initialize
    validate_configuration!
  end

  # Upload a file to R2
  #
  # @param key [String] The object key (path in bucket)
  # @param data [String] Binary data to upload
  # @param content_type [String] MIME type (default: application/pdf)
  # @return [String] The object URL
  def upload(key, data, content_type: "application/pdf")
    client.put_object(
      bucket: bucket_name,
      key: key,
      body: data,
      content_type: content_type
    )

    object_url(key)
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("R2 upload failed: #{e.message}")
    raise UploadError, "Failed to upload to R2: #{e.message}"
  end

  # Download a file from R2
  #
  # @param key [String] The object key
  # @return [String] Binary data
  def download(key)
    response = client.get_object(
      bucket: bucket_name,
      key: key
    )

    response.body.read
  rescue Aws::S3::Errors::NoSuchKey
    nil
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("R2 download failed: #{e.message}")
    raise DownloadError, "Failed to download from R2: #{e.message}"
  end

  # Check if an object exists
  #
  # @param key [String] The object key
  # @return [Boolean]
  def exists?(key)
    client.head_object(bucket: bucket_name, key: key)
    true
  rescue Aws::S3::Errors::NotFound
    false
  end

  # Delete an object
  #
  # @param key [String] The object key
  def delete(key)
    client.delete_object(bucket: bucket_name, key: key)
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("R2 delete failed: #{e.message}")
    raise UploadError, "Failed to delete from R2: #{e.message}"
  end

  # Generate a pre-signed URL for temporary access
  #
  # @param key [String] The object key
  # @param expires_in [Integer] Seconds until expiration (default: 1 hour)
  # @return [String] Pre-signed URL
  def signed_url(key, expires_in: 3600)
    signer = Aws::S3::Presigner.new(client: client)
    signer.presigned_url(
      :get_object,
      bucket: bucket_name,
      key: key,
      expires_in: expires_in
    )
  end

  # List objects with a prefix
  #
  # @param prefix [String] Key prefix to filter by
  # @return [Array<String>] List of keys
  def list(prefix: nil)
    response = client.list_objects_v2(
      bucket: bucket_name,
      prefix: prefix
    )

    response.contents.map(&:key)
  end

  private

  def client
    @client ||= Aws::S3::Client.new(
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      endpoint: endpoint,
      region: "auto",
      force_path_style: true
    )
  end

  def account_id
    ENV.fetch("R2_ACCOUNT_ID")
  end

  def access_key_id
    ENV.fetch("R2_ACCESS_KEY_ID")
  end

  def secret_access_key
    ENV.fetch("R2_SECRET_ACCESS_KEY")
  end

  def bucket_name
    ENV.fetch("R2_BUCKET", "cornerstone-payroll-paystubs")
  end

  def endpoint
    "https://#{account_id}.r2.cloudflarestorage.com"
  end

  def public_url
    ENV["R2_PUBLIC_URL"]
  end

  def object_url(key)
    if public_url.present?
      "#{public_url}/#{key}"
    else
      # Return a placeholder - actual access will be via signed URL
      "r2://#{bucket_name}/#{key}"
    end
  end

  def validate_configuration!
    missing = []
    missing << "R2_ACCOUNT_ID" unless ENV["R2_ACCOUNT_ID"].present?
    missing << "R2_ACCESS_KEY_ID" unless ENV["R2_ACCESS_KEY_ID"].present?
    missing << "R2_SECRET_ACCESS_KEY" unless ENV["R2_SECRET_ACCESS_KEY"].present?

    if missing.any?
      Rails.logger.warn("R2 Storage not configured. Missing: #{missing.join(', ')}")
      # Don't raise in development - allows testing without R2
      raise ConfigurationError, "R2 not configured: #{missing.join(', ')}" if Rails.env.production?
    end
  end

  def configured?
    ENV["R2_ACCOUNT_ID"].present? &&
      ENV["R2_ACCESS_KEY_ID"].present? &&
      ENV["R2_SECRET_ACCESS_KEY"].present?
  end
end
