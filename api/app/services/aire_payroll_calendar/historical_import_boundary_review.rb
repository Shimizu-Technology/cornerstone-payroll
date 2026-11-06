# frozen_string_literal: true

module AirePayrollCalendar
  # Review of retained preactivation imports only, never payment approval.
  class HistoricalImportBoundaryReview
    class Error < StandardError; end

    def initialize(source:)
      @source = source
    end

    def preview!
      connection = ApplicationRecord.connection
      id = connection.quote(@source.id)
      unless connection.select_value("SELECT historical_imports_precede_rollout(#{id})")
        raise Error, "Connected, changed, or unsupported historical imports prevent initial rollout selection"
      end
      @source.time_tracking_imports.where(status: "applied").find_each do |record|
        TimeTracking::PayrollBatchPayloadValidator.new(payload: record.raw_payload, start_date: record.start_date,
          end_date: record.end_date, allow_legacy_uncategorized: true).validate!
      end
      value = connection.select_value("SELECT historical_import_rollout_review(#{id})")
      value.is_a?(String) ? JSON.parse(value) : value
    rescue TimeTracking::PayrollBatchPayloadValidator::Error => error
      raise Error, "Historical import checksum/content validation failed: #{error.message}"
    end

    def verify!(accepted_sha256:)
      review = preview!
      return {} if review.fetch("inventory").empty?
      unless accepted_sha256.present? && accepted_sha256 == review.fetch("sha256")
        raise Error, "Review retained historical imports and supply their exact HISTORICAL_IMPORTS_SHA256 before moving the boundary"
      end
      review
    end
  end
end
