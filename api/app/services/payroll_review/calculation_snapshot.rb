# frozen_string_literal: true

require "digest"

module PayrollReview
  class CalculationSnapshot
    SCHEMA_VERSION = "v1"
    VOLATILE_COLUMNS = %w[created_at updated_at].freeze
    PAY_PERIOD_FIELDS = %w[
      id company_id start_date end_date pay_date notes run_purpose includes_base_salary
      includes_recurring_items run_purpose_source parallel_run cycle corrects_pay_period_id
      correction_status source_pay_period_id company_pay_schedule_id company_workweek_id
    ].freeze

    def initialize(pay_period:)
      @pay_period = pay_period
    end

    def call
      snapshot = {
        "schema_version" => SCHEMA_VERSION,
        "pay_period" => pay_period.attributes.slice(*PAY_PERIOD_FIELDS).transform_values { |value| normalize(value) },
        "payroll_items" => payroll_item_snapshots,
        "source_manifest" => source_manifest
      }

      {
        snapshot: snapshot,
        source_manifest: snapshot.fetch("source_manifest"),
        checksum: Digest::SHA256.hexdigest(JSON.generate(canonicalize(snapshot)))
      }
    end

    private

    attr_reader :pay_period

    def payroll_item_snapshots
      pay_period.payroll_items.includes(
        :employee,
        :payroll_item_deductions,
        :payroll_item_field_entries,
        :time_tracking_entry_allocations
      ).order(:employee_id, :id).map do |item|
        stable_attributes(item).merge(
          "employee" => item.employee.attributes.slice("id", "first_name", "last_name"),
          "payroll_item_deductions" => item.payroll_item_deductions.sort_by(&:id).map { |row| stable_attributes(row) },
          "payroll_item_field_entries" => item.payroll_item_field_entries.sort_by(&:id).map { |row| stable_attributes(row) },
          "time_tracking_entry_allocations" => item.time_tracking_entry_allocations.sort_by(&:id).map { |row| stable_attributes(row) }
        )
      end
    end

    def source_manifest
      {
        "payroll_intake_packages" => pay_period.payroll_intake_sessions.current.order(:source_type, :package_revision, :id).map do |session|
          {
            "id" => session.id,
            "source_type" => session.source_type,
            "package_id" => session.package_id,
            "package_revision" => session.package_revision,
            "import_hash" => session.import_hash,
            "parser_version" => session.parser_version,
            "status" => session.status,
            "applied_at" => normalize(session.applied_at),
            "documents" => session.documents.order(:position, :id).map do |document|
              {
                "id" => document.id,
                "filename" => document.filename,
                "sha256" => document.sha256,
                "source_role" => document.source_role
              }
            end,
            "rows" => session.rows.order(:position, :id).map do |row|
              stable_attributes(row, except: %w[source_payload]).merge(
                "source_payload_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonicalize(row.source_payload || {})))
              )
            end
          }
        end,
        "time_tracking_imports" => pay_period.time_tracking_imports.where(status: "applied").order(:id).map do |time_import|
          stable_attributes(time_import, except: %w[raw_payload processed_payload]).merge(
            "raw_payload_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonicalize(time_import.raw_payload || {}))),
            "processed_payload_sha256" => Digest::SHA256.hexdigest(JSON.generate(canonicalize(time_import.processed_payload || {})))
          )
        end
      }
    end

    def stable_attributes(record, except: [])
      record.attributes.except(*(VOLATILE_COLUMNS + Array(except))).transform_values { |value| normalize(value) }
    end

    def canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.to_h do |key|
          original_value = value.key?(key) ? value[key] : value[key.to_sym]
          [ key, canonicalize(original_value) ]
        end
      when Array
        value.map { |item| canonicalize(item) }
      else
        normalize(value)
      end
    end

    def normalize(value)
      case value
      when BigDecimal then value.to_s("F")
      when Time, ActiveSupport::TimeWithZone then value.utc.iso8601(6)
      when Date then value.iso8601
      when Hash, Array then canonicalize(value)
      else value
      end
    end
  end
end
