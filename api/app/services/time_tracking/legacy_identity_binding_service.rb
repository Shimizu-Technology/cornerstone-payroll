# frozen_string_literal: true

module TimeTracking
  class LegacyIdentityBindingService
    class Error < StandardError; end

    def initialize(source:, actor:, manifest_sha256:, client:)
      @source, @actor, @digest, @client = source, actor, manifest_sha256, client
    end

    def verify!(evidence:, identity:)
      allocation = @source.time_tracking_entry_allocations.find(evidence.fetch("allocation_id"))
      mapping = @source.time_tracking_employee_mappings.find(evidence.fetch("mapping_id"))
      uuid = TimeTrackingEmployeeMapping.normalize_uuid(evidence.fetch("source_user_uuid"))
      import = allocation.time_tracking_import
      unless @source.remote_identity_pinned? && allocation.source_user_uuid.nil? && import.finalized_batch? &&
             allocation.company_id == @source.company_id && allocation.employee_id == identity.fetch("employee_id").to_i &&
             identity.fetch("source_user_uuid") == uuid && identity.fetch("source_user_id").to_s == allocation.source_user_id &&
             mapping.company_id == allocation.company_id && mapping.employee_id == allocation.employee_id &&
             mapping.source_user_id == allocation.source_user_id && (mapping.source_user_uuid.nil? || mapping.source_user_uuid == uuid) &&
             evidence.fetch("source_time_entry_id").to_s == allocation.source_time_entry_id &&
             evidence.fetch("source_line_key") == allocation.line_key &&
             evidence.fetch("original_work_date") == allocation.original_work_date.iso8601 &&
             evidence.fetch("batch_checksum") == import.external_batch_checksum &&
             evidence.fetch("external_batch_id") == import.external_batch_id &&
             evidence.fetch("source_instance_id") == @source.expected_source_instance_id
        raise Error, "Legacy allocation, numeric mapping, owner, installation, or batch evidence changed"
      end
      existing = allocation.time_tracking_legacy_identity_binding
      if existing
        unless existing.matching_allocation?(allocation) && existing.source_user_uuid == uuid &&
               existing.accepted_manifest_sha256 == @digest &&
               existing.source_time_entry_version == evidence.fetch("source_time_entry_version") &&
               existing.time_tracking_employee_mapping_id == mapping.id &&
               existing.source_total_hours == decimal(evidence.fetch("source_total_hours"))
          raise Error, "Legacy identity binding replay differs from its accepted evidence"
        end
        return existing
      end
      remote = @client.payroll_cockpit_time_entry(entry_id: allocation.source_time_entry_id).fetch("time_entry")
      version = evidence.fetch("source_time_entry_version")
      unless version.is_a?(Integer) && version >= 0 && remote.fetch("version") == version &&
             remote.fetch("id").to_s == allocation.source_time_entry_id &&
             remote.fetch("work_date") == allocation.original_work_date.iso8601 &&
             remote.dig("employee", "id").to_s == allocation.source_user_id &&
             remote.dig("employee", "payroll_integration_id").to_s.downcase == uuid &&
             remote.dig("employee", "name").to_s.squish == identity.fetch("source_employee_name", identity.fetch("employee_name")) &&
             decimal(remote.fetch("hours")) == decimal(evidence.fetch("source_total_hours"))
        raise Error, "Legacy AIRE entry identity, version, date, or captured hours changed"
      end
      TimeTrackingLegacyIdentityBinding.new(
        time_tracking_entry_allocation: allocation, company: allocation.company, time_tracking_source: @source,
        employee: allocation.employee, time_tracking_employee_mapping: mapping, approved_by: @actor,
        source_user_id: allocation.source_user_id, source_user_uuid: uuid,
        source_time_entry_id: allocation.source_time_entry_id, source_time_entry_version: version,
        source_line_key: allocation.line_key, original_work_date: allocation.original_work_date,
        external_batch_id: import.external_batch_id, batch_checksum: import.external_batch_checksum,
        source_instance_id: @source.expected_source_instance_id, accepted_manifest_sha256: @digest,
        source_total_hours: decimal(evidence.fetch("source_total_hours"))
      )
    rescue ActiveRecord::RecordNotFound, KeyError, ArgumentError => e
      raise Error, "Legacy identity evidence is incomplete or no longer available: #{e.message}"
    end

    def apply!(binding:, accepted_manifest_sha256:, release_owner:)
      unless accepted_manifest_sha256.to_s.downcase == @digest && release_owner.to_s.strip.present?
        raise Error, "Legacy identity bindings require an accepted manifest and named release owner"
      end
      return binding if binding.persisted?

      binding.release_owner = release_owner.to_s.strip
      binding.approved_rollout_digest = @digest
      binding.time_tracking_entry_allocation.with_lock do
        binding.time_tracking_employee_mapping.with_lock { binding.save! }
      end
      binding
    end

    private

    def decimal(value)
      number = BigDecimal(value.to_s)
      raise Error, "Captured source hours must be finite" unless number.finite?
      number
    end
  end
end
