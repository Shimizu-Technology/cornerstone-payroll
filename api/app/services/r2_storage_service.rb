# frozen_string_literal: true

require "aws-sdk-s3"
require "fileutils"

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
  class InvalidKeyError < StandardError; end
  LOCAL_STORAGE_ROOT = Rails.root.join("tmp", "local_r2_storage")

  def initialize
    validate_configuration!
  end

  # Upload a file to R2
  #
  # @param key [String] The object key (path in bucket)
  # @param data [String, IO] Binary data or readable IO to upload
  # @param content_type [String] MIME type (default: application/pdf)
  # @return [String] The object URL
  def upload(key, data, content_type: "application/pdf")
    return upload_locally(key, data) unless configured?

    client.put_object(
      bucket: bucket_name,
      key: key,
      body: rewindable_upload_body(data),
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
    return download_locally(key) unless configured?

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
    return File.exist?(local_path_for(key)) unless configured?

    client.head_object(bucket: bucket_name, key: key)
    true
  rescue Aws::S3::Errors::NotFound
    false
  end

  # Delete an object
  #
  # @param key [String] The object key
  def delete(key)
    return delete_locally(key) unless configured?

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
    return "local-r2://#{key}" unless configured?

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
    unless configured?
      pattern = prefix.present? ? File.join(local_storage_root.to_s, prefix, "**", "*") : File.join(local_storage_root.to_s, "**", "*")
      return Dir.glob(pattern).select { |path| File.file?(path) }.map { |path| Pathname(path).relative_path_from(local_storage_root).to_s }
    end

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
    ENV.fetch("R2_BUCKET_NAME", ENV.fetch("R2_BUCKET", "cornerstone-payroll"))
  end

  def endpoint
    ENV.fetch("R2_ENDPOINT", "https://#{account_id}.r2.cloudflarestorage.com")
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

  def local_storage_root
    LOCAL_STORAGE_ROOT
  end

  def local_path_for(key)
    root = File.expand_path(local_storage_root.to_s)
    candidate = File.expand_path(key.to_s, root)
    return Pathname(candidate) if candidate == root || candidate.start_with?("#{root}#{File::SEPARATOR}")

    raise InvalidKeyError, "Invalid storage key"
  end

  def upload_locally(key, data)
    path = local_path_for(key)
    FileUtils.mkdir_p(path.dirname)
    if data.respond_to?(:read)
      rewindable_upload_body(data)
      File.open(path, "wb") { |file| IO.copy_stream(data, file) }
    else
      File.binwrite(path, data)
    end
    "local-r2://#{key}"
  rescue InvalidKeyError => e
    raise UploadError, e.message
  rescue StandardError => e
    Rails.logger.error("Local R2 upload failed: #{e.message}")
    raise UploadError, "Failed to upload locally: #{e.message}"
  end

  def download_locally(key)
    path = local_path_for(key)
    return nil unless File.exist?(path)

    File.binread(path)
  rescue InvalidKeyError => e
    raise DownloadError, e.message
  rescue StandardError => e
    Rails.logger.error("Local R2 download failed: #{e.message}")
    raise DownloadError, "Failed to download locally: #{e.message}"
  end

  def delete_locally(key)
    path = local_path_for(key)
    File.delete(path) if File.exist?(path)
  rescue InvalidKeyError => e
    raise UploadError, e.message
  rescue StandardError => e
    Rails.logger.error("Local R2 delete failed: #{e.message}")
    raise UploadError, "Failed to delete locally: #{e.message}"
  end

  def rewindable_upload_body(data)
    data.rewind if data.respond_to?(:rewind)
    data
  end
end
