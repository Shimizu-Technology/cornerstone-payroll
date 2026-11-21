# frozen_string_literal: true

module TaxWorkHours
  # Pulls an import's range from Tax one calendar month at a time, then
  # replaces every stored row in that range in a single transaction. If any
  # month fails, nothing already stored changes.
  class Importer
    # Raised inside the replacement transaction when this worker no longer
    # holds a live claim; rolls the replacement back.
    class Superseded < StandardError; end
    class LeaseLost < StandardError; end

    def self.call(import, client: Client.new)
      new(import, client:).call
    end

    def initialize(import, client:)
      @import = import
      @client = client
    end

    # Returns the import. Does nothing when another worker holds it or it has
    # already finished.
    def call
      @token = @import.claim!
      return @import unless @token

      payloads = []
      month_ranges.each do |first, last|
        payloads << [ first, last, @client.fetch(start_date: first, end_date: last) ]
        raise LeaseLost unless @import.renew_lease!(@token)
      end
      replace!(payloads)
      @import.reload
    rescue Superseded, LeaseLost
      # Nothing was saved. If no other worker took the import over, record
      # that this one ran out of time; otherwise leave it to that worker.
      @import.expire_lease!(@token)
      @import.reload
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
        # Same lock order as WorkHourImport.reserve!: the organization row
        # (FOR NO KEY UPDATE), then the import row. A refresh reserved during
        # this save waits on the organization row instead of deadlocking.
        Organization.lock(WorkHourImport::ORGANIZATION_LOCK).find(@import.organization_id)
        # Commit only while this worker holds a live claim. The status, token
        # and lease are checked by the database while the row is locked; a
        # worker that was replaced, or whose lease ran out (even after its
        # last renewal), must not overwrite newer hours.
        current = WorkHourImport.lock.where(id: @import.id, status: "running", claim_token: @token)
                                .where("lease_expires_at > ?", Time.current).first
        raise Superseded unless current

        WorkHourRow.where(organization_id: @import.organization_id, work_date: @import.range_start..@import.range_end).delete_all
        rows.each_slice(1_000) { |slice| WorkHourRow.insert_all!(slice) }
        current.update!(
          status: "succeeded",
          finished_at: Time.current,
          claim_token: nil,
          lease_expires_at: nil,
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

    # Records the failure only while this worker still holds the import, so a
    # superseded worker never marks its replacement as failed.
    def fail!(code, message)
      if @token
        WorkHourImport.where(id: @import.id, status: "running", claim_token: @token)
                      .update_all(status: "failed", finished_at: Time.current, claim_token: nil, lease_expires_at: nil,
                                  error_code: code, error_message: message, updated_at: Time.current)
      end
      @import.reload
    end
  end
end
