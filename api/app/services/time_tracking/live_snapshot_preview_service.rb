# frozen_string_literal: true

module TimeTracking
  # Captures the AIRE entries that are payable *before* the post-pay cutoff.
  # The source response is retained unchanged; only stable payroll fields are
  # hashed, since AIRE's generated_at changes on every read.
  class LiveSnapshotPreviewService < BatchImportPreviewService
    VALIDATION_VERSION = "aire_live_snapshot_v1"

    def initialize(pay_period:, source:, start_date: nil, end_date: nil, actor:)
      super(pay_period: pay_period, source: source, start_date: start_date, end_date: end_date)
      @actor = actor
    end

    def call
      validate_request!
      raise ArgumentError, "Capture live AIRE hours before committing payroll" unless pay_period.can_edit?

      workweek = legal_workweek!
      source_response = Client.for_payroll_actor(source, actor: @actor).payroll_cockpit_manual_review(
        start_date: start_date.iso8601,
        end_date: end_date.iso8601,
        external_pay_period_id: pay_period.id
      )
      validate_live_response!(source_response)
      checksum = snapshot_checksum(source_response)
      raw = source_response.merge(
        "source" => "aire_services",
        "schema_version" => VALIDATION_VERSION,
        "batch_id" => "LIVE-#{checksum}",
        "cutoff_at" => source_response.fetch("generated_at")
      )
      validate_source_workweeks!(raw, workweek)

      processed = process(raw, workweek: workweek).merge(
        validation_version: VALIDATION_VERSION,
        snapshot_checksum: checksum,
        captured_at: source_response.fetch("generated_at")
      )
      processed[:rows].each do |row|
        source_employee = source_response.fetch("employees").find do |employee|
          employee.fetch("source_user_id").to_s == row.fetch(:source_user_id)
        end
        negative_correction = Array(source_employee&.fetch("adjustments", [])).any? do |adjustment|
          %w[total_hours regular_hours overtime_hours].any? { |key| BigDecimal(adjustment.fetch(key).to_s).negative? }
        end
        if negative_correction
          row[:warnings] << {
            code: "negative_correction",
            message: "AIRE has a negative correction for this employee. Review it in the payroll correction workflow before importing."
          }
          row[:ready] = false
        end
        next if row[:match_method] == "saved_mapping"

        row[:warnings] << {
          code: "unconfirmed_employee_mapping",
          message: "Confirm the permanent AIRE-to-Cornerstone employee link before importing"
        }
        row[:ready] = false
      end
      processed[:ready] = processed[:rows].all? { |row| row[:ready] }
      warnings = processed.fetch(:rows).flat_map do |row|
        row.fetch(:warnings).map do |warning|
          warning.merge(source_user_id: row.fetch(:source_user_id), display_name: row.fetch(:source_display_name))
        end
      end

      import = persist_preview!(raw, processed, warnings, checksum)
      source.update!(last_synced_at: Time.current)
      import
    end

    def self.snapshot_checksum(response)
      CanonicalPayload.checksum(response.slice(
        "start_date", "end_date", "employees", "exclusions", "issues", "summary"
      ))
    end

    private

    def snapshot_checksum(response)
      self.class.snapshot_checksum(response)
    end

    def validate_live_response!(response)
      unless response.is_a?(Hash) && response["start_date"] == start_date.iso8601 &&
             response["end_date"] == end_date.iso8601 && response["generated_at"].present? &&
             response["employees"].is_a?(Array) && response["exclusions"].is_a?(Array) &&
             response["issues"].is_a?(Hash) && response["summary"].is_a?(Hash)
        raise ArgumentError, "AIRE live hours are incomplete or for a different pay period"
      end

      seen = Set.new
      response.fetch("employees").each do |employee|
        unless employee.is_a?(Hash) && employee["source_user_id"].to_s.present? &&
               employee["adjustments"].is_a?(Array)
          raise ArgumentError, "AIRE live hours contain an invalid employee"
        end
        uuid = TimeTrackingEmployeeMapping.normalize_uuid(employee["source_user_uuid"])
        raise ArgumentError, "AIRE employee is missing a permanent identity" if uuid.blank?

        Array(employee["adjustments"]).each do |adjustment|
          key = adjustment["line_key"].to_s
          entry_id = adjustment["source_time_entry_id"].to_s
          version = Integer(adjustment["source_time_entry_version"].to_s, 10)
          total = BigDecimal(adjustment["total_hours"].to_s)
          regular = BigDecimal(adjustment["regular_hours"].to_s)
          overtime = BigDecimal(adjustment["overtime_hours"].to_s)
          raise ArgumentError, "AIRE live hours contain a duplicate source line" unless seen.add?([ entry_id, key ])
          if key.blank? || entry_id.blank? || version.negative? || total != regular + overtime
            raise ArgumentError, "AIRE live hours contain an invalid source line"
          end
          Date.iso8601(adjustment.fetch("original_work_date"))
          Date.iso8601(adjustment.fetch("original_week_start"))
        end
      end
    rescue ArgumentError, TypeError, KeyError => e
      raise if e.message == "AIRE live hours contain a duplicate source line"

      raise ArgumentError, "AIRE live hours contain an invalid source line"
    end

    def persist_preview!(raw, processed, warnings, checksum)
      attrs = {
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: start_date,
        end_date: end_date,
        fetch_start_date: start_date,
        fetch_end_date: end_date,
        source_payload_hash: checksum,
        status: "previewed",
        raw_payload: raw,
        processed_payload: processed,
        warnings: warnings
      }
      lookup = attrs.slice(:pay_period, :time_tracking_source, :start_date, :end_date, :source_payload_hash)
      import = TimeTrackingImport.where.not(status: "superseded").find_by(lookup)
      return import if import

      TimeTrackingImport.create!(attrs)
    rescue ActiveRecord::RecordNotUnique
      TimeTrackingImport.where.not(status: "superseded").find_by!(lookup)
    end
  end
end
