# frozen_string_literal: true

module TimeTracking
  # Local operational evidence only. No producer calls, names, payment amounts,
  # error bodies or credentials belong on this protected summary.
  class ConnectorHealth
    LINK_LIMIT = 5
    PREVIEW_ROW_LIMIT = 5_000

    def initialize(source, now: Time.current)
      @source = source
      @now = now
    end

    def call
      {
        source_id: source.id, company_id: source.company_id, active: source.active?,
        as_of: now.iso8601, evidence_scope: "local_records",
        last_source_activity_at: source.last_synced_at,
        receipts: {
          batch: delivery_summary(AirePayrollAcknowledgement.where(time_tracking_import_id: imports.select(:id))),
          entry: delivery_summary(AirePayrollEntryAcknowledgement.where(time_tracking_import_id: imports.select(:id))
            .joins(:payroll_item, :time_tracking_import).where(payroll_items: { company_id: source.company_id })
            .where("payroll_items.pay_period_id = time_tracking_imports.pay_period_id"))
        },
        calendar: calendar_summary,
        latest_import_mapping_review: mapping_review,
        reconciliation: reconciliation_summary,
        source_settlement_holds: { status: "not_fetched", count: nil },
        source_roster_missing_mappings: { status: "not_fetched", count: nil }
      }
    end

    private

    attr_reader :source, :now

    def imports
      @imports ||= source.time_tracking_imports.joins(:pay_period)
        .where(pay_periods: { company_id: source.company_id })
    end

    def delivery_summary(scope)
      pending = scope.where(delivered_at: nil)
      failed = pending.where.not(last_error: [ nil, "" ])
      oldest = pending.minimum(:created_at)
      {
        recorded_count: scope.count, pending_count: pending.count, failed_count: failed.count,
        last_success_at: scope.maximum(:delivered_at),
        failure_record_updated_at: failed.maximum(:updated_at),
        oldest_pending_at: oldest, oldest_pending_age_seconds: age(oldest),
        pay_period_ids: imports.where(id: pending.select(:time_tracking_import_id))
          .order(:created_at, :id).limit(LINK_LIMIT).pluck(:pay_period_id).uniq
      }
    end

    def calendar_summary
      periods = source.aire_payroll_calendar_periods.where(company_id: source.company_id)
        .joins(:pay_period).where(pay_periods: { company_id: source.company_id })
      publications = AirePayrollCalendarPublication.where(aire_payroll_calendar_period_id: periods.select(:id))
      latest = publications.where(<<~SQL.squish)
        NOT EXISTS (SELECT 1 FROM aire_payroll_calendar_publications newer
          WHERE newer.aire_payroll_calendar_period_id = aire_payroll_calendar_publications.aire_payroll_calendar_period_id
            AND newer.schedule_version > aire_payroll_calendar_publications.schedule_version)
      SQL
      pending = latest.where(delivery_status: %w[pending failed])
      oldest = pending.minimum(:created_at)
      {
        supported: source.supports?(:payroll_calendar_v2), recorded_period_count: periods.count,
        unacknowledged_revision_count: pending.count,
        failed_revision_count: pending.where(delivery_status: "failed").count,
        last_success_at: publications.maximum(:delivered_at),
        oldest_pending_at: oldest, oldest_pending_age_seconds: age(oldest),
        pay_period_ids: periods.where(id: pending.select(:aire_payroll_calendar_period_id))
          .order(:created_at, :id).limit(LINK_LIMIT).pluck(:pay_period_id)
      }
    end

    def mapping_review
      latest = imports.select(:id, :pay_period_id, :created_at).order(created_at: :desc, id: :desc).first
      return { status: "not_recorded", missing_count: nil } unless latest

      # Aggregate only a valid bounded stored preview; do not load the source
      # roster or arbitrary raw/processed payload into this response.
      count_sql = <<~SQL.squish
        CASE WHEN jsonb_typeof(processed_payload->'rows') = 'array' THEN
          CASE WHEN jsonb_array_length(processed_payload->'rows') <= #{PREVIEW_ROW_LIMIT}
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(processed_payload->'rows') row
              WHERE jsonb_typeof(row) <> 'object' OR NOT row ? 'employee_id'
                OR COALESCE(row->>'source_user_id', '') = '')
          THEN (SELECT COUNT(DISTINCT row->>'source_user_id')
            FROM jsonb_array_elements(processed_payload->'rows') row
            WHERE COALESCE(row->>'employee_id', '') = '') END
        END
      SQL
      missing = imports.where(id: latest.id).pick(Arel.sql(count_sql))
      { status: missing.nil? ? "unavailable" : "recorded", as_of: latest.created_at,
        pay_period_id: latest.pay_period_id, missing_count: missing }
    end

    def reconciliation_summary
      reviews = source.time_tracking_classification_reconciliations.where(company_id: source.company_id, status: "pending")
        .joins(:pay_period).where(pay_periods: { company_id: source.company_id })
      manual = source.time_tracking_manual_allocations.where(company_id: source.company_id)
        .joins(:pay_period).where(pay_periods: { company_id: source.company_id }).where.not(status: "voided")
      failed = manual.where.not(last_sync_error: [ nil, "" ])
      {
        pending_classification_count: reviews.count,
        manual_pending_commit_count: manual.where(status: "pending_commit").count,
        manual_sync_failed_count: failed.count,
        pay_period_ids: (reviews.order(:created_at, :id).limit(LINK_LIMIT).pluck(:pay_period_id) +
          manual.where(status: "pending_commit").or(failed)
            .order(:created_at, :id).limit(LINK_LIMIT).pluck(:pay_period_id)).uniq.first(LINK_LIMIT)
      }
    end

    def age(timestamp)
      timestamp && [ (now - timestamp).to_i, 0 ].max
    end
  end
end
