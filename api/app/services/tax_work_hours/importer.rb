# frozen_string_literal: true

module TaxWorkHours
  # Pulls an import's range from Tax one calendar month at a time, then
  # replaces every stored row in that range in a single transaction. If any
  # month fails, nothing already stored changes.
  class Importer
    LOCK_NAMESPACE = 72_604 # "work hours" import lock, combined with the organization id.

    def self.call(import, client: Client.new)
      new(import, client:).call
    end

    def initialize(import, client:)
      @import = import
      @client = client
    end

    def call
      @import.update!(status: "running", started_at: Time.current, error_code: nil, error_message: nil)
      payloads = month_ranges.map { |first, last| [ first, last, @client.fetch(start_date: first, end_date: last) ] }
      replace!(payloads)
      @import
    rescue Error => e
      fail!(e.code, e.message)
    rescue StandardError => e
      Rails.logger.error("[TaxWorkHours] import #{@import.id} failed: #{e.class}: #{e.message}")
      fail!("unexpected", "The refresh stopped unexpectedly. Nothing was changed. Try again, and tell Leon if it keeps happening.")
      raise unless Rails.env.production?

      @import
    end

    def month_ranges
      ranges = []
      first = @import.range_start
      while first <= @import.range_end
        last = [ first.end_of_month, @import.range_end ].min
        ranges << [ first, last ]
        first = last + 1
      end
      ranges
    end

    private

    def replace!(payloads)
      now = Time.current
      rows = payloads.flat_map do |first, last, payload|
        payload.fetch("rows").filter_map do |row|
          work_date = Date.iso8601(row["work_date"])
          next unless work_date.between?(first, last)

          normalize(row, work_date, now)
        end
      end
      counts = payloads.map { |_first, _last, payload| payload["counts"].is_a?(Hash) ? payload["counts"] : {} }

      WorkHourRow.transaction do
        WorkHourRow.connection.execute(
          WorkHourRow.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", LOCK_NAMESPACE, @import.organization_id ])
        )
        WorkHourRow.where(organization_id: @import.organization_id, work_date: @import.range_start..@import.range_end).delete_all
        rows.each_slice(1_000) { |slice| WorkHourRow.insert_all!(slice) }
        @import.update!(
          status: "succeeded",
          finished_at: Time.current,
          row_count: rows.length,
          total_hours: rows.sum(BigDecimal("0")) { |row| row[:hours] },
          pending_entries: counts.sum { |count| count["pending_entries"].to_i },
          denied_entries: counts.sum { |count| count["denied_entries"].to_i },
          open_clock_entries: counts.sum { |count| count["open_clock_entries"].to_i },
          schema_version: payloads.last&.dig(2, "schema_version"),
          source_generated_at: parse_time(payloads.last&.dig(2, "generated_at"))
        )
      end
    end

    def normalize(row, work_date, now)
      {
        organization_id: @import.organization_id,
        work_hour_import_id: @import.id,
        tax_user_id: row["tax_user_id"],
        email: row["email"].to_s.strip.downcase.presence,
        work_date: work_date,
        tax_client_id: row["unassigned"] ? nil : row["client_id"],
        client_name: row["client_name"].to_s.strip.presence || "Unassigned",
        system_kind: row["system_kind"].presence,
        unassigned: row["unassigned"] == true || row["client_id"].nil?,
        category_id: integer_or_nil(row["category_id"]),
        category: row["category"].to_s.strip.presence,
        task_id: integer_or_nil(row["task_id"]),
        task: row["task"].to_s.strip.presence,
        period_type: row["period_type"].presence,
        period_start: parse_date(row["period_start"]),
        period_label: row["period_label"].presence,
        hours: BigDecimal(row["hours"].to_s).round(2),
        minutes: row["minutes"].to_i,
        entry_ids: Array(row["entry_ids"]).select { |id| id.is_a?(Integer) },
        approval_state: row["approval_state"],
        created_at: now,
        updated_at: now
      }
    end

    def integer_or_nil(value)
      value.is_a?(Integer) ? value : nil
    end

    def parse_date(value)
      value.present? ? Date.iso8601(value.to_s) : nil
    rescue Date::Error
      nil
    end

    def parse_time(value)
      value.present? ? Time.iso8601(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    def fail!(code, message)
      @import.update!(status: "failed", finished_at: Time.current, error_code: code, error_message: message)
      @import
    end
  end
end
