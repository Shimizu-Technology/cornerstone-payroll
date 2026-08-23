# frozen_string_literal: true

# Active Record Encryption Configuration
#
# Production accepts either these environment variables:
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
