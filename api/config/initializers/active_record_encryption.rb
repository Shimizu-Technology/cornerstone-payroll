# frozen_string_literal: true

# Active Record Encryption Configuration
#
# For production, set these environment variables:
# - ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
# - ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
# - ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
#
# For development/test, we use fallback keys (DO NOT use in production!)

if Rails.env.development? || Rails.env.test?
  Rails.application.config.active_record.encryption.primary_key = ENV.fetch(
    "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY",
    "development-primary-key-32-chars!"
  )
  Rails.application.config.active_record.encryption.deterministic_key = ENV.fetch(
    "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY",
    "development-deterministic-key32!"
  )
  Rails.application.config.active_record.encryption.key_derivation_salt = ENV.fetch(
    "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT",
    "development-salt-for-derivation!"
  )
end
