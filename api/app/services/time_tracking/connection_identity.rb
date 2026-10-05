# frozen_string_literal: true

module TimeTracking
  class ConnectionIdentity
    PROTOCOL = "shimizu_time_payroll"
    SUPPORTED_PROTOCOL_VERSIONS = [ "1.0" ].freeze
    CAPABILITY_PATTERN = /\A[a-z0-9_]+\z/
    Result = Data.define(:legacy, :source_instance_id, :protocol, :protocol_version, :capabilities, :source_identifier, :policy_constraints) do
      def initialize(source_identifier: nil, policy_constraints: {}, **attributes)
        super(**attributes, source_identifier: source_identifier, policy_constraints: policy_constraints)
      end
    end

    class Error < StandardError; end

    def self.validate!(source:, payload:)
      new(source: source, payload: payload).validate!
    end

    def self.verify_and_pin!(source:, payload:, now: Time.current)
      result = validate!(source: source, payload: payload)
      return result if result.legacy

      source.with_lock do
        source.reload
        if source.remote_identity_pinned? && source.expected_source_instance_id != result.source_instance_id
          raise Error, "#{source.name} installation identity changed; review the connection before importing payroll time"
        end

        if source.remote_source_identifier.present? && source.remote_source_identifier != result.source_identifier
          raise Error, "#{source.name} producer identity changed; review the connection before importing payroll time"
        end

        source.update!(
          expected_source_instance_id: result.source_instance_id,
          source_protocol: result.protocol,
          source_protocol_version: result.protocol_version,
          source_capabilities: result.capabilities,
          remote_source_identifier: result.source_identifier || source.remote_source_identifier,
          source_policy_constraints: result.policy_constraints,
          identity_verified_at: now
        )
      end
      result
    end

    def initialize(source:, payload:)
      @source = source
      @payload = payload
    end

    def validate!
      integration = payload["integration"] || payload.dig("export", "integration")
      if integration.blank?
        if source.remote_identity_pinned?
          raise Error, "#{source.name} omitted its pinned installation identity"
        end

        return Result.new(legacy: true, source_instance_id: nil, protocol: nil, protocol_version: nil, capabilities: [], source_identifier: nil, policy_constraints: {})
      end
      raise Error, "#{source.name} returned an invalid integration identity" unless integration.is_a?(Hash)

      protocol = integration["protocol"].to_s
      protocol_version = integration["protocol_version"].to_s
      source_instance_id = integration["source_instance_id"].to_s.downcase
      capabilities = integration["capabilities"]
      identifier = (integration["source_type"] || payload["source"] || source.remote_source_identifier).to_s.presence
      if identifier && !identifier.match?(/\A[a-z0-9_]+\z/)
        raise Error, "#{source.name} returned an invalid producer identifier"
      end
      if source.remote_source_identifier.present? && identifier != source.remote_source_identifier
        raise Error, "#{source.name} producer identity changed; review the connection before importing payroll time"
      end
      if identifier && ((payload["source"].present? && payload["source"] != identifier) || (source.source_type != "custom" && identifier != source.source_type))
        raise Error, "#{source.name} returned inconsistent producer identity"
      end
      constraints = integration.fetch("policy_constraints", {})
      unless constraints.is_a?(Hash) && constraints.keys.all? { |key| key.in?(%w[time_zones workweek_starts cutoff_rules frequencies]) } &&
        constraints.values.all? { |values| values.is_a?(Array) && values.all? { |value| value.is_a?(String) && value.length <= 128 } }
        raise Error, "#{source.name} returned invalid policy constraints"
      end

      raise Error, "#{source.name} uses unsupported integration protocol #{protocol.presence || 'unknown'}" unless protocol == PROTOCOL
      unless SUPPORTED_PROTOCOL_VERSIONS.include?(protocol_version)
        raise Error, "#{source.name} uses unsupported integration protocol version #{protocol_version.presence || 'unknown'}"
      end
      unless source_instance_id.match?(TimeTrackingSource::UUID_PATTERN)
        raise Error, "#{source.name} returned an invalid installation identity"
      end
      unless capabilities.is_a?(Array) && capabilities.all? { |value| value.is_a?(String) && value.match?(CAPABILITY_PATTERN) }
        raise Error, "#{source.name} returned invalid integration capabilities"
      end
      if source.remote_identity_pinned? && source.expected_source_instance_id != source_instance_id
        raise Error, "#{source.name} installation identity changed; review the connection before importing payroll time"
      end

      Result.new(
        legacy: false,
        source_instance_id: source_instance_id,
        protocol: protocol,
        protocol_version: protocol_version,
        capabilities: capabilities.uniq.sort,
        source_identifier: identifier,
        policy_constraints: constraints
      )
    end

    private

    attr_reader :source, :payload
  end
end
