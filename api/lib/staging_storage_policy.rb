# frozen_string_literal: true

require "digest"
require "uri"

# The approved authority is independent from runtime SDK/R2 overrides. Object
# access remains server-side so downloads pass through artifact marking.
class StagingStoragePolicy
  class << self
    def validate!(env: ENV, bucket: nil, access_key: nil, endpoint: nil, account_id: nil, region: nil, secret_access_key: nil)
      return true unless StagingOutboundPolicy.staging?(env)

      expected = required("STAGING_STORAGE_BUCKET", env)
      production = required("PRODUCTION_STORAGE_BUCKET", env)
      actual = bucket || env["R2_BUCKET_NAME"] || env["R2_BUCKET"] || env["AWS_S3_BUCKET"]
      valid = expected.match?(/(?:\A|[-_])staging(?:[-_]|\z)/) && expected != production && actual == expected
      fail_config!("STAGING_STORAGE_BUCKET / PRODUCTION_STORAGE_BUCKET") unless valid

      key = access_key || env["R2_ACCESS_KEY_ID"] || env["AWS_ACCESS_KEY_ID"]
      approved = required("STAGING_STORAGE_ACCESS_KEY_SHA256", env)
      denied = required("PRODUCTION_STORAGE_ACCESS_KEY_SHA256", env)
      fingerprint = Digest::SHA256.hexdigest(key.to_s)
      valid_key = approved.match?(/\A[0-9a-f]{64}\z/) && denied.match?(/\A[0-9a-f]{64}\z/) && approved != denied && fingerprint == approved && fingerprint != denied
      fail_config!("STAGING_STORAGE_ACCESS_KEY_SHA256 / PRODUCTION_STORAGE_ACCESS_KEY_SHA256") unless valid_key
      secret = secret_access_key || env[env.key?("R2_ACCESS_KEY_ID") ? "R2_SECRET_ACCESS_KEY" : "AWS_SECRET_ACCESS_KEY"]
      fail_config!("storage SECRET_ACCESS_KEY") if secret.to_s.strip.empty?

      approved_account = required("STAGING_STORAGE_ACCOUNT_ID", env)
      denied_account = required("PRODUCTION_STORAGE_ACCOUNT_ID", env)
      r2 = env.key?("R2_ACCOUNT_ID")
      pattern = r2 ? /\A[0-9a-f]{32}\z/ : /\A[0-9]{12}\z/
      actual_account = account_id || env[r2 ? "R2_ACCOUNT_ID" : "AWS_ACCOUNT_ID"]
      unless approved_account.match?(pattern) && denied_account.match?(pattern) && approved_account != denied_account && actual_account == approved_account
        fail_config!("STAGING_STORAGE_ACCOUNT_ID / PRODUCTION_STORAGE_ACCOUNT_ID / AWS_ACCOUNT_ID")
      end

      approved_endpoint = authority!(required("STAGING_STORAGE_ENDPOINT", env))
      denied_endpoint = authority!(required("PRODUCTION_STORAGE_ENDPOINT", env))
      if r2
        canonical = "https://#{approved_account}.r2.cloudflarestorage.com"
        actual_endpoint = env["R2_ENDPOINT"] || "https://#{actual_account}.r2.cloudflarestorage.com"
        production_host = "#{denied_account}.r2.cloudflarestorage.com"
      else
        approved_region = required("STAGING_STORAGE_REGION", env)
        actual_region = region || env["AWS_REGION"]
        fail_config!("STAGING_STORAGE_REGION / AWS_REGION") unless approved_region.match?(/\A[a-z]{2}-[a-z]+-\d\z/) && actual_region == approved_region
        canonical = "https://s3.#{approved_region}.amazonaws.com"
        actual_endpoint = "https://s3.#{env['AWS_REGION']}.amazonaws.com"
      end
      valid_endpoint = approved_endpoint == canonical && approved_endpoint != denied_endpoint && URI(approved_endpoint).host != production_host && authority!(actual_endpoint) == approved_endpoint
      valid_endpoint &&= authority!(endpoint) == approved_endpoint if endpoint
      fail_config!("STAGING_STORAGE_ENDPOINT / PRODUCTION_STORAGE_ENDPOINT / R2_ENDPOINT") unless valid_endpoint
      true
    end

    def hosts(env)
      validate!(env: env)
      host = URI(required("STAGING_STORAGE_ENDPOINT", env)).host
      return [ host ] if env.key?("R2_ACCOUNT_ID")

      [ host, "#{env.fetch('STAGING_STORAGE_BUCKET')}.#{host}" ]
    end

    def block_urls!(env: ENV)
      return true unless StagingOutboundPolicy.staging?(env)

      raise StagingOutboundPolicy::Blocked, "#{StagingOutboundPolicy::LABEL}: raw storage URLs and direct uploads are disabled; use marked API downloads"
    end

    private

    def required(name, env)
      StagingOutboundPolicy.require_setting!(name, env)
    end

    def fail_config!(name)
      raise StagingOutboundPolicy::ConfigurationError, "Unsafe #{name}"
    end

    def authority!(value)
      uri = URI.parse(value.to_s)
      valid = uri.is_a?(URI::HTTPS) && uri.port == 443 && uri.host && uri.userinfo.nil? && uri.path.empty? && uri.query.nil? && uri.fragment.nil?
      fail_config!("storage ENDPOINT: HTTPS authority required") unless valid
      "https://#{uri.host}"
    rescue URI::InvalidURIError
      fail_config!("storage ENDPOINT")
    end
  end
end
