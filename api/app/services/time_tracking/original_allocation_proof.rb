# frozen_string_literal: true

module TimeTracking
  class OriginalAllocationProof
    RATE_KEYS = %w[rate rate_cents effective_rate_cents source_effective_rate_cents].freeze

    def self.earning_identity(line)
      category = line["category"] || {}
      stable_id = line["source_category_id"].presence || category["id"].presence
      stable_key = category["key"].presence
      raise ArgumentError, "The original earning category has no stable identity" unless stable_id || stable_key
      { id: stable_id&.to_s, key: stable_key&.to_s,
        line_rates: line.slice(*RATE_KEYS), category_rates: category.slice(*RATE_KEYS) }.deep_stringify_keys
    end

    def initialize(payroll_item:, source:, source_user_id:, source_user_uuid:)
      @item = payroll_item
      @source = source
      @source_user_id = source_user_id.to_s
      @source_user_uuid = source_user_uuid
    end

    def call
      allocations = @item.time_tracking_entry_allocations.reload.includes(:time_tracking_import).order(:id).to_a
      raise ArgumentError, "Original allocation coverage is missing" if allocations.empty?
      lines = []
      batches = []
      allocations.group_by(&:time_tracking_import_id).each_value do |rows|
        import = rows.first.time_tracking_import
        validate_batch!(import)
        employees = Array(import.raw_payload["employees"]).select do |employee|
          employee["source_user_id"].to_s == @source_user_id && employee["source_user_uuid"] == @source_user_uuid
        end
        raise ArgumentError, "Original allocation union has ambiguous source employee identity" unless employees.one?
        frozen = employees.first.fetch("adjustments")
        expected = frozen.map { |line| line_identity(line) }.sort
        actual = rows.map { |row| [ row.source_time_entry_id.to_s, row.line_key.to_s ] }.sort
        unless expected == actual && rows.all? { |row| matching_allocation?(row, frozen) }
          raise ArgumentError, "Original allocation coverage must exactly match every frozen employee line"
        end
        lines.concat(frozen)
        batches << import.attributes.slice("id", "pay_period_id", "time_tracking_source_id", "external_batch_id",
          "external_batch_checksum", "source_payload_hash", "contract_version", "source_cutoff_at")
      end
      unless lines.map { |line| self.class.earning_identity(line) }.uniq.one? &&
        allocations.sum(&:regular_hours) == @item.hours_worked.to_d &&
        allocations.sum(&:overtime_hours) == @item.overtime_hours.to_d
        raise ArgumentError, "Original allocation union must use one earning/rate and sum to the original paycheck REG/OT totals"
      end
      { allocations: allocations, lines: lines, evidence: { allocations: allocations.map(&:attributes), batches: batches.sort_by { |batch| batch["id"] },
        native_earnings: @item.payroll_item_earnings.order(:id).map(&:attributes) } }
    rescue PayrollBatchPayloadValidator::Error, ConnectionIdentity::Error => e
      raise ArgumentError, e.message
    end

    private

    def validate_batch!(import)
      PayrollBatchPayloadValidator.new(payload: import.raw_payload, start_date: import.start_date, end_date: import.end_date,
        expected_source: @source.connector.source_identifier).validate!
      identity = ConnectionIdentity.validate!(source: @source, payload: import.raw_payload)
      unless import.status == "applied" && import.pay_period_id == @item.pay_period_id &&
        import.time_tracking_source_id == @source.id && @item.company_id == @source.company_id &&
        identity.source_instance_id == @source.expected_source_instance_id &&
        import.raw_payload["batch_id"] == import.external_batch_id &&
        import.raw_payload.dig("export", "checksum") == import.external_batch_checksum &&
        import.source_payload_hash == import.external_batch_checksum && import.contract_version == "2.0" &&
        import.source_cutoff_at == Time.iso8601(import.raw_payload.fetch("cutoff_at"))
        raise ArgumentError, "Original allocation union has changed batch, source installation or payroll ownership"
      end
    end

    def line_identity(line)
      [ line["source_time_entry_id"].to_s, line["line_key"].to_s ]
    end

    def matching_allocation?(row, frozen)
      line = frozen.find { |candidate| line_identity(candidate) == [ row.source_time_entry_id.to_s, row.line_key.to_s ] }
      line && row.valid? && row.company_id == @item.company_id && row.pay_period_id == @item.pay_period_id &&
        row.payroll_item_id == @item.id && row.employee_id == @item.employee_id && row.time_tracking_source_id == @source.id &&
        row.source_user_id == @source_user_id && row.verified_source_user_uuid == @source_user_uuid &&
        row.source_kind.in?(%w[current carryover]) && row.source_kind == line["source_kind"] &&
        row.original_work_date.iso8601 == line["original_work_date"] && row.category_snapshot == (line["category"] || {}) &&
        %w[total_hours regular_hours overtime_hours].all? { |key| row.public_send(key) == line[key].to_d && row.public_send(key) >= 0 }
    end
  end
end
