# frozen_string_literal: true

# Active Record Encryption Configuration
#
# Production uses the complete Rails credential key set when present, preserving
# compatibility with existing encrypted records. A complete environment key set
# remains supported for deployments without encrypted Rails credentials:
# - ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
# - ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
# - ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
#
# or matching Rails credentials under:
# active_record_encryption:
#   primary_key:
#   deterministic_key:
#   key_derivation_salt:
#
# For development/test, we use fallback keys (DO NOT use in production!)

require Rails.root.join("lib/active_record_encryption_configuration")

ActiveRecordEncryptionConfiguration.apply!(
  config: Rails.application.config.active_record.encryption,
  environment: Rails.env,
  env: ENV,
  credentials: Rails.application.credentials
)

if ActiveRecordEncryptionConfiguration.sources_conflict?(
  environment: Rails.env,
  env: ENV,
  credentials: Rails.application.credentials
)
  Rails.logger.error(
    "Active Record encryption sources conflict; Rails credentials remain authoritative. " \
    "Remove or correct the environment key set before the production readiness gate."
  )
end
