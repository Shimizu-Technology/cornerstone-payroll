# frozen_string_literal: true

require "uri"

module TimeTracking
  # The wire protocol is shared; a producer's business policy is not. Existing
  # AIRE connections retain their deployed contract while new compatible
  # producers must verify their identity and advertised capabilities first.
  class Connector
    AIRE_CAPABILITIES = %w[time_summary_v1 finalized_batch_v2 payroll_calendar_v2 exact_line_receipts_v2 employee_directory payroll_cockpit account_linking manual_allocations payment_attestations].freeze
    PROTOCOL = "shimizu_time_payroll"

    def self.authorization_origin_allowed?(origin, allow_test_loopback: false)
      uri = URI.parse(origin.to_s)
      return false unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil? &&
        uri.query.nil? && uri.fragment.nil? && uri.path.in?([ "", "/" ])
      return true if uri.scheme == "https" && uri.port == 443

      allow_test_loopback && Rails.env.test? && ENV["E2E_TEST_MODE"] == "true" &&
        uri.scheme == "http" && uri.hostname.in?([ "localhost", "127.0.0.1", "::1" ])
    rescue URI::InvalidURIError
      false
    end

    def initialize(source)
      @source = source
    end

    def source_identifier
      @source.remote_source_identifier.presence || (@source.source_type unless @source.source_type == "custom")
    end

    def capabilities
      return AIRE_CAPABILITIES if @source.source_type == "aire_services" && @source.source_capabilities.blank?

      return [] unless @source.remote_identity_pinned? && @source.source_protocol == PROTOCOL && @source.source_protocol_version == "1.0"

      @source.source_capabilities || []
    end

    def supports?(capability)
      capabilities.include?(capability.to_s) && (source_identifier.present? || capability.to_s == "time_summary_v1")
    end

    def require!(capability)
      return if supports?(capability)

      raise ArgumentError, "#{@source.name} does not support #{capability.to_s.tr('_', ' ')}. Verify a compatible connection before using this operation."
    end

    def aire_policy?
      @source.source_type == "aire_services"
    end

    def calendar_contract(pay_period)
      require!(:payroll_calendar_v2)
      return AirePayrollCalendar::Contract.new(pay_period) if aire_policy?

      contract = PayrollCalendarContract.new(pay_period)
      payload = contract.payload
      constraints = @source.source_policy_constraints
      checks = {
        "time_zones" => payload.fetch("time_zone"),
        "workweek_starts" => payload.dig("overtime_policy", "workweek_start"),
        "cutoff_rules" => payload.fetch("cutoff_rule"),
        "frequencies" => pay_period.company_pay_schedule&.frequency || CompanyPaySchedule.for_date(pay_period.company_id, pay_period.start_date)&.frequency
      }
      unless checks.all? { |key, value| Array(constraints[key]).include?(value) }
        raise AirePayrollCalendar::Contract::Error.new("#{@source.name} has not verified support for this company's calendar and workweek policy", code: "source_policy_unsupported")
      end
      contract
    end

    def employee_evidence_path(employee_id:, period_id: nil, entry_id: nil)
      return nil unless aire_policy?
      return nil unless employee_id.to_s.match?(/\A[1-9]\d*\z/)
      return nil if period_id.present? && !period_id.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      return nil if entry_id.present? && !entry_id.to_s.match?(/\A[1-9]\d*\z/)

      query = { tab: "hours", period: period_id, entry: entry_id }.compact.to_query
      "/admin/users/#{employee_id}?#{query}"
    end

    def authorization_origins
      configured = @source.authorization_origin.presence
      return self.class.authorization_origin_allowed?(configured) ? [ configured ] : [] if configured
      return [] unless aire_policy?

      public_origin = ENV["AIRE_PUBLIC_URL"]
      unless public_origin.nil?
        return self.class.authorization_origin_allowed?(public_origin, allow_test_loopback: true) ? [ public_origin ] : []
      end

      %w[https://aire-services-guam.netlify.app https://app.aireservicesguam.com]
    end
  end
end
