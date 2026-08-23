# frozen_string_literal: true

module ActiveRecordEncryptionConfiguration
  KEY_SPECS = {
    primary_key: "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY",
    deterministic_key: "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY",
    key_derivation_salt: "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
  }.freeze

  DEVELOPMENT_DEFAULTS = {
    primary_key: "development-primary-key-32-chars!",
    deterministic_key: "development-deterministic-key32!",
    key_derivation_salt: "development-salt-for-derivation!"
  }.freeze

  class MissingConfiguration < StandardError; end

  class << self
    def apply!(config:, environment:, env:, credentials:)
      values = resolve(environment: environment, env: env, credentials: credentials)
      values.each { |key, value| config.public_send("#{key}=", value) }
      values
    end

    def resolve(environment:, env:, credentials:)
      values = KEY_SPECS.to_h do |credential_key, env_key|
        value = env[env_key].presence || credentials.dig(:active_record_encryption, credential_key).presence
        value ||= DEVELOPMENT_DEFAULTS.fetch(credential_key) unless environment.production?
        [ credential_key, value ]
      end

      missing = values.filter_map do |credential_key, value|
        KEY_SPECS.fetch(credential_key) if value.blank?
      end
      if missing.any?
        raise MissingConfiguration,
          "Missing Active Record encryption configuration: #{missing.join(', ')}"
      end

      values
    end

    def configured?(config)
      KEY_SPECS.keys.all? { |key| config.public_send(key).present? }
    end
  end
end
