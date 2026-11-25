# frozen_string_literal: true

module EmployeeBulkImport
  # Stores previewed employee SSNs encrypted in Rails.cache, cryptographically
  # bound to the company, acting user, and preview session ID, with a hard
  # 2-hour max age enforced inside the authenticated ciphertext as well as by
  # the cache TTL. Never logs SSNs or ciphertext.
  module SsnPreviewCache
    SALT = "employee_bulk_import/ssn_preview_cache/v1"
    PURPOSE_PREFIX = "employee_bulk_import_ssn_preview"
    TTL = 2.hours
    PREVIEW_ID_PATTERN = /\A[0-9a-f-]{16,64}\z/i

    module_function

    def write(company_id:, user_id:, preview_id:, tokens:)
      return false if tokens.blank? || !valid_binding?(company_id, user_id, preview_id)

      payload = {
        "company_id" => company_id.to_i,
        "user_id" => user_id.to_i,
        "preview_id" => preview_id.to_s,
        "tokens" => tokens.transform_keys(&:to_s).transform_values(&:to_s)
      }
      encrypted = encryptor.encrypt_and_sign(
        payload,
        expires_in: TTL,
        purpose: purpose_for(company_id, user_id, preview_id)
      )
      Rails.cache.write(cache_key(company_id, user_id, preview_id), encrypted, expires_in: TTL)
      true
    end

    def read(company_id:, user_id:, preview_id:)
      return nil unless valid_binding?(company_id, user_id, preview_id)

      encrypted = Rails.cache.read(cache_key(company_id, user_id, preview_id))
      return nil unless encrypted.is_a?(String) && encrypted.present?

      payload = encryptor.decrypt_and_verify(
        encrypted,
        purpose: purpose_for(company_id, user_id, preview_id)
      )
      return nil unless payload.is_a?(Hash)
      return nil unless payload["company_id"] == company_id.to_i &&
        payload["user_id"] == user_id.to_i &&
        payload["preview_id"] == preview_id.to_s &&
        payload["tokens"].is_a?(Hash)

      payload["tokens"]
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
      Rails.logger.warn("[EmployeeBulkImport::SsnPreviewCache] Rejected invalid or expired SSN preview payload")
      nil
    end

    def delete(company_id:, user_id:, preview_id:)
      return false unless valid_binding?(company_id, user_id, preview_id)

      Rails.cache.delete(cache_key(company_id, user_id, preview_id))
      true
    end

    def valid_binding?(company_id, user_id, preview_id)
      company_id.to_i.positive? && user_id.to_i.positive? && PREVIEW_ID_PATTERN.match?(preview_id.to_s)
    end
    private_class_method :valid_binding?

    def cache_key(company_id, user_id, preview_id)
      "bulk_import_ssn:v2:#{company_id.to_i}:#{user_id.to_i}:#{preview_id}"
    end
    private_class_method :cache_key

    def purpose_for(company_id, user_id, preview_id)
      "#{PURPOSE_PREFIX}:#{company_id.to_i}:#{user_id.to_i}:#{preview_id}"
    end
    private_class_method :purpose_for

    def encryptor
      secret = Rails.application.key_generator.generate_key(SALT, ActiveSupport::MessageEncryptor.key_len)
      ActiveSupport::MessageEncryptor.new(secret, serializer: JSON)
    end
    private_class_method :encryptor
  end
end
