# frozen_string_literal: true

module StagingStorageHelpers
  def staging_storage_env(provider: :r2)
    staging_account = provider == :r2 ? "a" * 32 : "111122223333"
    production_account = provider == :r2 ? "b" * 32 : "999988887777"
    endpoint = provider == :r2 ? "https://#{staging_account}.r2.cloudflarestorage.com" : "https://s3.us-east-1.amazonaws.com"
    production_endpoint = provider == :r2 ? "https://#{production_account}.r2.cloudflarestorage.com" : "https://s3.us-west-2.amazonaws.com"
    common = {
      "DEPLOYMENT_ENV" => "staging", "CONNECTED_PAYROLL_MODE" => "enabled",
      "STAGING_STORAGE_BUCKET" => "synthetic-staging-bucket",
      "PRODUCTION_STORAGE_BUCKET" => "synthetic-live-bucket",
      "STAGING_STORAGE_ACCESS_KEY_SHA256" => Digest::SHA256.hexdigest("synthetic-staging-key"),
      "PRODUCTION_STORAGE_ACCESS_KEY_SHA256" => Digest::SHA256.hexdigest("synthetic-live-key"),
      "STAGING_STORAGE_ACCOUNT_ID" => staging_account,
      "PRODUCTION_STORAGE_ACCOUNT_ID" => production_account,
      "STAGING_STORAGE_ENDPOINT" => endpoint,
      "PRODUCTION_STORAGE_ENDPOINT" => production_endpoint,
      "STAGING_STORAGE_REGION" => "us-east-1"
    }
    if provider == :r2
      common.merge("R2_ACCOUNT_ID" => staging_account, "R2_ENDPOINT" => endpoint, "R2_BUCKET" => common["STAGING_STORAGE_BUCKET"], "R2_ACCESS_KEY_ID" => "synthetic-staging-key", "R2_SECRET_ACCESS_KEY" => "synthetic-only")
    else
      common.merge("AWS_ACCOUNT_ID" => staging_account, "AWS_REGION" => "us-east-1", "AWS_S3_BUCKET" => common["STAGING_STORAGE_BUCKET"], "AWS_ACCESS_KEY_ID" => "synthetic-staging-key", "AWS_SECRET_ACCESS_KEY" => "synthetic-only")
    end
  end
end
