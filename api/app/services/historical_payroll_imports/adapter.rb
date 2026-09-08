# frozen_string_literal: true

module HistoricalPayrollImports
  class Adapter
    REQUIRED_CAPABILITIES = %i[
      source_file_retention
      cutover_verification
      client_bootstrap
      ytd_bridge
    ].freeze
    REQUIRED_CORE_CAPABILITIES = %i[source_file_retention cutover_verification].freeze

    def contract
      {
        key: key,
        label: label,
        description: description,
        importer_version: importer_version,
        accepted_extensions: accepted_extensions,
        max_files: max_files,
        max_file_bytes: max_file_bytes,
        max_bundle_bytes: max_bundle_bytes,
        capabilities: capabilities,
        limitations: limitations
      }
    end

    def parse(files:)
      parser_class.new(files: files).call
    end

    def source_file(**attributes)
      parser_class::SourceFile.new(**attributes)
    end

    def supports_verification_version?(version)
      supported_verification_versions.include?(version)
    end

    def tax_wage_version?(version)
      tax_wage_versions.include?(version)
    end

    def legacy_worker_snapshot_version?(version)
      legacy_worker_snapshot_versions.include?(version)
    end

    def validate_contract!
      required_values = %i[key label description importer_version parser_class].index_with { |name| public_send(name) }
      missing = required_values.select { |_name, value| value.blank? }.keys
      raise ArgumentError, "Historical import adapter is missing #{missing.join(', ')}" if missing.any?

      unknown_capabilities = capabilities.keys.map(&:to_sym) - REQUIRED_CAPABILITIES
      missing_capabilities = REQUIRED_CAPABILITIES - capabilities.keys.map(&:to_sym)
      invalid_capability_values = capabilities.values.any? { |value| value != true && value != false }
      if unknown_capabilities.any? || missing_capabilities.any? || invalid_capability_values
        raise ArgumentError, "Historical import adapter capabilities must exactly match the published contract"
      end
      unless REQUIRED_CORE_CAPABILITIES.all? { |capability| capabilities.fetch(capability) }
        raise ArgumentError, "Historical import adapters must retain source files and support cutover verification"
      end

      unless accepted_extensions.present? && accepted_extensions.all? { |extension| extension.to_s.start_with?(".") }
        raise ArgumentError, "Historical import adapter extensions must use dot-prefixed values"
      end
      unless [ max_files, max_file_bytes, max_bundle_bytes, max_workers, max_periods ].all? { |limit| limit.is_a?(Integer) && limit.positive? }
        raise ArgumentError, "Historical import adapter limits must be positive integers"
      end
      unless supported_verification_versions.include?(importer_version)
        raise ArgumentError, "Historical import adapter must verify its current importer version"
      end
      self
    end

    def max_workers
      parser_class::MAX_WORKER_COUNT
    end

    def max_periods
      parser_class::MAX_PERIOD_COUNT
    end
  end
end
