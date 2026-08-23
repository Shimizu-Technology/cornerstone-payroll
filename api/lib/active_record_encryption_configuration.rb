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
      return non_production_values(env) unless environment.production?

      credential_values = credential_values(credentials)
      environment_values = environment_values(env)

      return credential_values if complete?(credential_values)
      return environment_values if complete?(environment_values)

      raise MissingConfiguration,
        "Missing complete Active Record encryption configuration in Rails credentials or environment variables"
    end

    def configured?(config)
      KEY_SPECS.keys.all? { |key| config.public_send(key).present? }
    end

    def sources_conflict?(environment:, env:, credentials:)
      return false unless environment.production?

      credential_values = credential_values(credentials)
      environment_values = environment_values(env)
      return false unless present?(credential_values) && present?(environment_values)

      !complete?(credential_values) || !complete?(environment_values) || credential_values != environment_values
    end

    private

    def credential_values(credentials)
      KEY_SPECS.keys.to_h do |credential_key|
        [ credential_key, credentials.dig(:active_record_encryption, credential_key).presence ]
      end
    end

    def environment_values(env)
      KEY_SPECS.to_h do |credential_key, env_key|
        [ credential_key, env[env_key].presence ]
      end
    end

    def non_production_values(env)
      KEY_SPECS.to_h do |credential_key, env_key|
        [ credential_key, env[env_key].presence || DEVELOPMENT_DEFAULTS.fetch(credential_key) ]
      end
    end

    def complete?(values)
      values.values.all?(&:present?)
    end

    def present?(values)
      values.values.any?(&:present?)
    end
  end
end
