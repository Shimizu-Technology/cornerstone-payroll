# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "base64"
require "set"

module TimeTracking
  # Replays privately reviewed AIRE identities and historical payment evidence.
  # The manifest is intentionally supplied outside Git. A dry-run checks the
  # current AIRE and Cornerstone records before the explicitly authorized apply.
  # New source entries are never inferred to be paid from an old check.
  class VerifiedHistoryRollout
    class Error < StandardError; end

    VERSION = 1
    SOURCE_ENTRY_INTERVAL_SECONDS = 1.5

    def self.load_file!(path:, expected_sha256:)
      pathname = File.realpath(path)
      raise Error, "AIRE rollout manifest must be a private file" unless (File.stat(pathname).mode & 0o077).zero?

      bytes = File.binread(pathname)
      actual = Digest::SHA256.hexdigest(bytes)
      raise Error, "AIRE rollout manifest checksum differs" unless actual == expected_sha256.to_s.downcase

      JSON.parse(bytes).merge("_verified_sha256" => actual)
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "AIRE rollout manifest is unavailable"
    rescue JSON::ParserError
      raise Error, "AIRE rollout manifest is not valid JSON"
    end

    def self.load_encrypted_file!(path:, key_hex:, expected_sha256:)
      raise Error, "AIRE rollout decryption key must be 32 bytes" unless key_hex.to_s.match?(/\A[0-9a-f]{64}\z/i)

      envelope = JSON.parse(File.binread(path))
      unless envelope.is_a?(Hash) && envelope["version"] == 1 && envelope["algorithm"] == "aes-256-gcm"
        raise Error, "AIRE rollout encrypted manifest format is unsupported"
      end
      nonce = Base64.strict_decode64(envelope.fetch("nonce"))
      tag = Base64.strict_decode64(envelope.fetch("tag"))
      ciphertext = Base64.strict_decode64(envelope.fetch("ciphertext"))
      raise Error, "AIRE rollout encrypted manifest nonce or tag is invalid" unless nonce.bytesize == 12 && tag.bytesize == 16

      cipher = OpenSSL::Cipher.new("aes-256-gcm")
      cipher.decrypt
      cipher.key = [ key_hex ].pack("H*")
      cipher.iv = nonce
      cipher.auth_tag = tag
      cipher.auth_data = "cornerstone-aire-history-rollout-v1"
      bytes = cipher.update(ciphertext) + cipher.final
      actual = Digest::SHA256.hexdigest(bytes)
      raise Error, "AIRE rollout manifest checksum differs" unless actual == expected_sha256.to_s.downcase

      JSON.parse(bytes).merge("_verified_sha256" => actual)
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "AIRE rollout encrypted manifest is unavailable"
    rescue JSON::ParserError, KeyError, ArgumentError, OpenSSL::Cipher::CipherError
      raise Error, "AIRE rollout encrypted manifest cannot be authenticated"
    end

    def initialize(manifest:, actor:)
      @manifest = manifest
      @actor = actor
      @manifest_sha256 = manifest["_verified_sha256"] || Digest::SHA256.hexdigest(JSON.generate(manifest))
      @reviews = {}
      @live_entries = {}
    end

    def preview!
      validate_structure!
      validate_company!
      validate_history_scope!
      validate_identities!
      validate_legacy_bindings!
      validate_checks!
      validate_entries!
      validate_finalized_batch_entries!
      {
        identity_links: identities.length,
        delivered_checks: checks.length,
        exact_entries: entries.length,
        historical_classification_cases: classification_cases.length,
        finalized_batch_entries: finalized_batch_entries.length,
        new_source_entries_ignored: ignored_source_entry_count,
        history_coverage_verified: history_scope_verified?
      }
    end

    def apply!(accepted_manifest_sha256: nil, release_owner: nil)
      if Rails.env.production?
        unless accepted_manifest_sha256.to_s.downcase == @manifest_sha256 && release_owner.to_s.strip.present? &&
               manifest["source_instance_id"].present?
          raise Error, "Production history apply requires an accepted manifest, release owner, and installation identity"
        end
        source_rows = entries + classification_cases.flat_map { |row| row.fetch("source_entries") }
        unless finalized_batch_entries.all? { |row| row["source_user_uuid"].present? }
          raise Error, "Production history apply requires permanent identities on finalized payable lines"
        end
        unless source_rows.all? { |row| row["source_time_entry_version"].is_a?(Integer) }
          raise Error, "Production history apply requires captured source-entry versions"
        end
      end
      summary = preview!
      if accepted_manifest_sha256.present? && !history_scope_verified?
        raise Error, "Accepted history manifest leaves scoped source entries without a verified disposition"
      end
      apply_legacy_bindings!(accepted_manifest_sha256: accepted_manifest_sha256, release_owner: release_owner)
      apply_identities!
      apply_deliveries!
      apply_classification_cases!
      apply_exact_entries!
      apply_finalized_batch_payments!
      # Keep command IDs and approved bindings durable across remote failures.
      # AIRE requests cannot be rolled back by a Cornerstone SQL transaction.
      # Publish completion only after a fresh coverage read and local verification.
      validate_history_scope!
      @source.with_lock do
        validate_completion_context!
        if accepted_manifest_sha256.present? && !history_scope_verified?
          raise Error, "Accepted history manifest leaves scoped source entries without a verified disposition"
        end
        verify_applied!
        approved_coverage = accepted_manifest_sha256.to_s.downcase == @manifest_sha256 && release_owner.to_s.strip.present? && history_scope_verified?
        AireVerifiedHistoryRolloutReceipt.find_or_create_by!(time_tracking_source: @source,
          manifest_sha256: @manifest_sha256, coverage_verified: approved_coverage) do |receipt|
          receipt.company = @company
          receipt.time_tracking_source = @source
          receipt.identity_count = identities.length
          receipt.paid_source_entry_count = entries.length +
            classification_cases.sum { |row| row.fetch("source_time_entry_ids").length } + finalized_batch_entries.length
          receipt.completed_at = Time.current
          receipt.source_instance_id = @source.expected_source_instance_id
          if accepted_manifest_sha256.to_s.downcase == @manifest_sha256 && release_owner.to_s.strip.present?
            receipt.accepted_manifest_sha256 = @manifest_sha256
            receipt.approved_by = actor
            receipt.release_owner = release_owner.to_s.strip
            receipt.coverage_verified = history_scope_verified?
          end
        end
      end
      summary
    end

    private

    attr_reader :manifest, :actor

    def identities
      manifest.fetch("identity_links")
    end

    def checks
      manifest.fetch("delivered_checks")
    end

    def entries
      manifest.fetch("issued_entries")
    end

    def classification_cases
      manifest.fetch("classification_cases")
    end

    def finalized_batch_entries
      manifest.fetch("finalized_batch_entries")
    end

    def validate_structure!
      raise Error, "AIRE rollout manifest version is unsupported" unless manifest.is_a?(Hash) && manifest["version"] == VERSION
      %w[company_id source_id actor_id identity_links delivered_checks issued_entries classification_cases finalized_batch_entries].each do |key|
        raise Error, "AIRE rollout manifest is missing #{key}" unless manifest.key?(key)
      end
      raise Error, "The rollout actor differs from the verified manifest" unless manifest["actor_id"].to_i == actor.id
      %w[identity_links delivered_checks issued_entries classification_cases finalized_batch_entries].each do |key|
        raise Error, "AIRE rollout #{key} must be a list" unless manifest[key].is_a?(Array)
      end
      raise Error, "AIRE rollout identity list contains duplicates" unless unique?(identities.map { |row| row.fetch("source_user_uuid") }) &&
        unique?(identities.map { |row| row.fetch("employee_id") })
      raise Error, "AIRE rollout check list contains duplicates" unless unique?(checks.map { |row| row.fetch("payroll_item_id") })
      raise Error, "AIRE rollout source entries contain duplicates" unless unique?(entries.map { |row| [ row.fetch("payroll_item_id").to_i, row.fetch("source_time_entry_id").to_s ] })
      raise Error, "AIRE rollout finalized-batch entries contain duplicates" unless unique?(finalized_batch_entries.map { |row| [ row.fetch("payroll_item_id"), row.fetch("source_time_entry_id"), row["source_line_key"] ] })
      raise Error, "AIRE rollout classification cases contain duplicates" unless unique?(classification_cases.map { |row| row.fetch("payroll_item_id") })
      case_ids = classification_cases.flat_map { |row| row.fetch("source_time_entry_ids") }.map(&:to_s)
      raise Error, "AIRE rollout classification entries are duplicated" unless unique?(case_ids)
      manual_ids = case_ids + entries.map { |row| row.fetch("source_time_entry_id").to_s }
      raise Error, "AIRE rollout entry belongs to two paths" if (case_ids & entries.map { |row| row.fetch("source_time_entry_id").to_s }).any? ||
        (manual_ids & finalized_batch_entries.map { |row| row.fetch("source_time_entry_id").to_s }).any?
      check_ids = checks.map { |row| row.fetch("payroll_item_id").to_i }
      referenced = entries.map { |row| row.fetch("payroll_item_id").to_i } +
        classification_cases.map { |row| row.fetch("payroll_item_id").to_i } +
        finalized_batch_entries.map { |row| row.fetch("payroll_item_id").to_i }
      raise Error, "AIRE rollout entry has no verified delivered check" unless (referenced - check_ids).empty?
      entries.each do |row|
        next unless row.key?("reconciliation_note")

        note = row["reconciliation_note"]
        unless note.is_a?(String) && note.strip.length.between?(10, 2_000)
          raise Error, "AIRE rollout reconciliation note must contain 10 to 2000 characters"
        end
      end
    rescue KeyError
      raise Error, "AIRE rollout manifest has an incomplete record"
    end

    def validate_company!
      @company = Company.find_by(id: manifest.fetch("company_id"))
      raise Error, "AIRE rollout company changed" unless @company&.name == manifest.fetch("company_name")
      @source = @company.time_tracking_sources.find_by(id: manifest.fetch("source_id"))
      raise Error, "AIRE rollout source changed" unless @source&.active? && @source.source_type == "aire_services"
      if manifest["source_instance_id"].present? && (!@source.remote_identity_pinned? || @source.expected_source_instance_id != manifest["source_instance_id"])
        raise Error, "AIRE rollout installation identity changed"
      end
      raise Error, "AIRE rollout actor cannot approve historical reconciliation for this company" unless
        StaffRolePolicy.historical_reconciliation_allowed?(actor, @company)
      linked = TimeTracking::Client.new(@source).payroll_account_link(external_actor_id: actor.id)
        .dig("account_link")
      unless linked&.fetch("connected", false) == true &&
             linked.fetch("aire_user_email", "").to_s.strip.casecmp?(actor.email.to_s.strip)
        raise Error, "The verified rollout administrator is not linked to the same AIRE account"
      end
      @client = TimeTracking::Client.for_payroll_actor(@source, actor: actor)
    end

    def validate_identities!
      identities.each do |row|
        employee = @company.employees.find_by(id: row.fetch("employee_id"))
        unless employee&.full_name&.squish == row.fetch("employee_name") && employee.status == row.fetch("employee_status")
          raise Error, "Payroll employee #{row.fetch('employee_id')} changed since identity verification"
        end
        source_id = row.fetch("source_user_id").to_s
        uuid = TimeTrackingEmployeeMapping.normalize_uuid(row.fetch("source_user_uuid"))
        remote = @client.payroll_cockpit_employee(employee_id: source_id).fetch("employee")
        unless remote["id"].to_s == source_id &&
               remote["payroll_integration_id"].to_s.downcase == uuid &&
               remote["full_name"].to_s.squish == row.fetch("source_employee_name", row.fetch("employee_name"))
          raise Error, "AIRE employee #{source_id} changed since identity verification"
        end
        existing = @source.time_tracking_employee_mappings.where(employee_id: employee.id).or(
          @source.time_tracking_employee_mappings.where(source_user_id: source_id)
        ).or(@source.time_tracking_employee_mappings.where(source_user_uuid: uuid)).distinct.to_a
        raise Error, "AIRE employee #{source_id} has a conflicting payroll link" if existing.many? ||
          existing.any? { |mapping| mapping.employee_id != employee.id || mapping.source_user_id != source_id ||
            (mapping.source_user_uuid.present? && mapping.source_user_uuid != uuid) }
      end
    end

    def legacy_identity_bindings
      manifest.fetch("legacy_identity_bindings", [])
    end

    def legacy_binding_service
      @legacy_binding_service ||= LegacyIdentityBindingService.new(source: @source, actor: actor,
        manifest_sha256: @manifest_sha256, client: @client)
    end

    def validate_legacy_bindings!
      raise Error, "Legacy bindings must be a list" unless legacy_identity_bindings.is_a?(Array)
      @legacy_bindings_by_allocation = {}
      legacy_identity_bindings.each do |evidence|
        identity = identities.find { |row| row.fetch("source_user_uuid") == evidence.fetch("source_user_uuid") }
        raise Error, "Legacy binding has no verified employee identity" unless identity
        binding = legacy_binding_service.verify!(evidence: evidence, identity: identity)
        if @legacy_bindings_by_allocation.key?(binding.time_tracking_entry_allocation_id)
          raise Error, "Legacy binding allocation is duplicated"
        end
        @legacy_bindings_by_allocation[binding.time_tracking_entry_allocation_id] = binding
      end
    rescue LegacyIdentityBindingService::Error, KeyError => e
      raise Error, e.message
    end

    def apply_legacy_bindings!(accepted_manifest_sha256:, release_owner:)
      @legacy_bindings_by_allocation.each_value do |binding|
        legacy_binding_service.apply!(binding: binding, accepted_manifest_sha256: accepted_manifest_sha256,
          release_owner: release_owner)
      end
    rescue LegacyIdentityBindingService::Error => e
      raise Error, e.message
    end

    def validate_history_scope_bound!
      date = manifest["history_through_work_date"]
      if date.blank?
        raise Error, "History scope is required for an existing source connection" if @source.historical_reconciliation_required? || Rails.env.production?
        return
      end
      @history_through_work_date = Date.iso8601(date)
      latest_regular_end = @company.pay_periods.where(status: "committed", cycle: "regular", run_purpose: "regular").maximum(:end_date)
      if latest_regular_end && @history_through_work_date < latest_regular_end
        raise Error, "History scope does not include the latest committed regular payroll"
      end
    end

    def validate_completion_context!
      @company.reload
      @actor = User.find(actor.id)
      unless @company.id == manifest.fetch("company_id").to_i && @company.name == manifest.fetch("company_name") &&
             @source.company_id == @company.id && @source.active? && @source.source_type == "aire_services"
        raise Error, "Historical rollout company or source changed before completion"
      end
      if manifest["source_instance_id"].present? && (!@source.remote_identity_pinned? || @source.expected_source_instance_id != manifest["source_instance_id"])
        raise Error, "Historical rollout installation changed before completion"
      end
      unless StaffRolePolicy.historical_reconciliation_allowed?(actor, @company)
        raise Error, "Historical rollout actor cannot approve completion for this company"
      end
      validate_history_scope_bound!
    rescue ActiveRecord::RecordNotFound
      raise Error, "Historical rollout company or actor changed before completion"
    end

    def validate_history_scope!
      validate_history_scope_bound!
      return unless @history_through_work_date

      date = @history_through_work_date.iso8601
      @history_inventory = []
      page = 1
      expected_count = nil
      expected_pages = nil
      expected_per_page = nil
      loop do
        raise Error, "Historical source inventory exceeded the bounded page limit" if page > 100
        response = @client.payroll_cockpit_history_entries(through_work_date: date, page: page)
        raise Error, "AIRE returned incomplete historical source inventory" unless response.is_a?(Hash)

        rows = response.fetch("time_entries")
        pagination = response.fetch("pagination")
        unless response["source_state"] == "current" && response["through_work_date"] == date &&
               rows.is_a?(Array) && rows.all? { |row| row.is_a?(Hash) } && pagination.is_a?(Hash) &&
               pagination["current_page"] == page && pagination["total_pages"].is_a?(Integer) &&
               pagination["total_pages"].between?(1, 100) && pagination["total_count"].is_a?(Integer) &&
               pagination["total_count"] >= 0 && pagination["per_page"].is_a?(Integer) && pagination["per_page"].between?(1, 250)
          raise Error, "AIRE returned incomplete historical source inventory"
        end
        per_page = pagination.fetch("per_page")
        total_pages = [ (pagination.fetch("total_count") + per_page - 1) / per_page, 1 ].max
        expected_rows = [ per_page, pagination.fetch("total_count") - (page - 1) * per_page ].min
        unless pagination["total_pages"] == total_pages && page <= total_pages && rows.length == expected_rows &&
               pagination["truncated"] == (page < total_pages)
          raise Error, "AIRE returned incomplete historical source inventory"
        end
        expected_count ||= pagination["total_count"]
        expected_pages ||= pagination["total_pages"]
        expected_per_page ||= per_page
        unless expected_count == pagination["total_count"] && expected_pages == pagination["total_pages"] && expected_per_page == per_page
          raise Error, "AIRE historical source inventory changed while paging"
        end
        @history_inventory.concat(rows)
        break if page >= pagination["total_pages"]
        page += 1
      end
      unless @history_inventory.length == expected_count
        raise Error, "AIRE returned incomplete historical source inventory"
      end
      keys = @history_inventory.map { |row| row.fetch("id").to_s }
      raise Error, "AIRE returned duplicate historical source entries" unless keys.uniq.length == keys.length
    rescue Date::Error, KeyError, TypeError => e
      raise Error, "Historical source scope is invalid or incomplete: #{e.message}"
    end

    def history_scope_verified?
      return false unless @history_inventory && @source.remote_identity_pinned? &&
                          manifest["source_instance_id"] == @source.expected_source_instance_id
      paid = entries + finalized_batch_entries + classification_cases.flat_map do |row|
        row.fetch("source_entries").map { |entry| entry.merge("source_user_uuid" => row.fetch("source_user_uuid")) }
      end
      paid_by_key = paid.group_by { |row| [ row.fetch("source_user_uuid"), row.fetch("source_time_entry_id").to_s, row["source_time_entry_version"] ] }
      paid_keys = paid_by_key.keys
      unpaid = Array(manifest["reviewed_unpaid_entries"])
      held = Array(manifest["held_source_entries"])
      unpaid_keys = unpaid.map { |row| [ row.fetch("source_user_uuid"), row.fetch("source_time_entry_id").to_s, row.fetch("source_time_entry_version") ] }
      held_keys = held.map { |row| [ row.fetch("source_user_uuid"), row.fetch("source_time_entry_id").to_s, row.fetch("source_time_entry_version") ] }
      dispositions = paid_keys + unpaid_keys + held_keys
      return false unless dispositions.uniq.length == dispositions.length
      @history_inventory.all? do |row|
        key = [ row.fetch("source_user_uuid"), row.fetch("id").to_s, row.fetch("version") ]
        next false unless dispositions.include?(key)
        total = coverage_hours(row.fetch("hours"))
        if paid_by_key.key?(key)
          regular = paid_by_key.fetch(key).sum { |entry| coverage_hours(entry.fetch("regular_hours")) }
          overtime = paid_by_key.fetch(key).sum { |entry| coverage_hours(entry.fetch("overtime_hours")) }
          next false unless regular + overtime == total
          if row.key?("regular_hours") || row.key?("overtime_hours")
            next false unless regular == coverage_hours(row.fetch("regular_hours")) &&
                              overtime == coverage_hours(row.fetch("overtime_hours"))
          end
        end
        !held_keys.include?(key) || row.dig("lifecycle", "status") == "payment_attested_pending_evidence"
      end
    rescue KeyError, ArgumentError, TypeError
      false
    end

    def coverage_hours(value)
      number = BigDecimal(value.to_s)
      raise ArgumentError, "Historical hours must be finite and nonnegative" unless number.finite? && number >= 0

      number
    end

    def validate_checks!
      checks.each do |row|
        item = PayrollItem.includes(:check_events, :pay_period).find_by(id: row.fetch("payroll_item_id"))
        unless item && item.company_id == @company.id && item.pay_period_id == row.fetch("pay_period_id").to_i &&
               item.pay_period.committed? && !item.voided? && item.employee_id == row.fetch("employee_id").to_i &&
               item.effective_payment_delivery_method == "paper_check" && item.check_number == row.fetch("check_number") &&
               money(item.net_pay) == money(row.fetch("net_pay")) && item.net_pay.to_d.positive? &&
               hours(item.hours_worked) == hours(row.fetch("regular_hours")) &&
               hours(item.overtime_hours) == hours(row.fetch("overtime_hours"))
          raise Error, "Issued payroll item #{row.fetch('payroll_item_id')} changed"
        end
        expected_date = Date.iso8601(row.fetch("delivered_on"))
        raise Error, "Check delivery date is in the future" if expected_date > PayrollBusinessClock.today
        deliveries = item.check_events.deliveries.where(check_number: item.check_number).to_a
        raise Error, "Check #{item.check_number} has conflicting delivery evidence" if deliveries.any? { |event| event.effective_on != expected_date }
      end
    end

    def validate_entries!
      by_uuid = identities.index_by do |row|
        TimeTrackingEmployeeMapping.normalize_uuid(row.fetch("source_user_uuid"))
      end
      all_entries = entries + classification_cases.flat_map do |row|
        row.fetch("source_entries").map { |entry| entry.merge("payroll_item_id" => row.fetch("payroll_item_id"), "source_user_uuid" => row.fetch("source_user_uuid")) }
      end
      all_entries.each do |row|
        uuid = TimeTrackingEmployeeMapping.normalize_uuid(row.fetch("source_user_uuid"))
        identity = by_uuid[uuid]
        raise Error, "AIRE rollout entry has an unverified employee" unless identity
        item = PayrollItem.find(row.fetch("payroll_item_id"))
        raise Error, "AIRE rollout entry points to another employee" unless item.employee_id == identity.fetch("employee_id").to_i
        existing = TimeTrackingManualAllocation.where(time_tracking_source: @source,
          payroll_item: item, source_time_entry_id: row.fetch("source_time_entry_id").to_s).where.not(status: "voided").first
        if existing
          unless existing.payroll_item_id == item.id && existing.source_user_uuid == uuid &&
                 existing.original_work_date.iso8601 == row.fetch("original_work_date") &&
                 (row["source_time_entry_version"].nil? || existing.source_time_entry_version == row["source_time_entry_version"]) &&
                 hours(existing.regular_hours) == hours(row.fetch("regular_hours")) &&
                 hours(existing.overtime_hours) == hours(row.fetch("overtime_hours")) &&
                 (!row.key?("reconciliation_note") || existing.reconciliation_note == row.fetch("reconciliation_note").strip)
            raise Error, "AIRE entry #{row.fetch('source_time_entry_id')} has conflicting payment evidence"
          end
          next
        end
        adjustment = live_entry(item.pay_period, uuid, row.fetch("source_time_entry_id"))
        unless adjustment && adjustment["original_work_date"] == row.fetch("original_work_date") &&
               hours(adjustment["regular_hours"]) >= hours(row.fetch("regular_hours")) &&
               hours(adjustment["overtime_hours"]) >= hours(row.fetch("overtime_hours")) &&
               (row["category_name"].nil? || adjustment.dig("category", "name") == row["category_name"]) &&
               adjustment["source_time_entry_version"].is_a?(Integer) &&
               (row["source_time_entry_version"].nil? || row["source_time_entry_version"] == adjustment["source_time_entry_version"])
          raise Error, "AIRE entry #{row.fetch('source_time_entry_id')} changed or is no longer unpaid"
        end
        @live_entries[row.fetch("source_time_entry_id").to_s] = adjustment
      end
      classification_cases.each do |row|
        item = PayrollItem.find(row.fetch("payroll_item_id"))
        selected = row.fetch("source_entries")
        unless selected.map { |entry| entry.fetch("source_time_entry_id").to_s }.sort == row.fetch("source_time_entry_ids").map(&:to_s).sort &&
               selected.sum { |entry| hours(entry.fetch("regular_hours")) + hours(entry.fetch("overtime_hours")) } ==
                 hours(item.hours_worked) + hours(item.overtime_hours)
          raise Error, "Historical classification case #{item.id} no longer matches the issued total hours"
        end
      end
    rescue ActiveRecord::RecordNotFound
      raise Error, "AIRE rollout references a missing payroll item"
    end

    def validate_finalized_batch_entries!
      @verified_finalized_allocations = []
      finalized_batch_entries.each do |row|
        item = PayrollItem.find_by(id: row.fetch("payroll_item_id"))
        allocations = TimeTrackingEntryAllocation.includes(:time_tracking_import).where(
          payroll_item_id: item&.id,
          source_time_entry_id: row.fetch("source_time_entry_id").to_s
        )
        allocations = allocations.where(line_key: row["source_line_key"]) if row["source_line_key"].present?
        allocation = allocations.one? ? allocations.first : nil
        unless item && allocation && allocation.time_tracking_import.finalized_batch? &&
               allocation.time_tracking_source_id == @source.id &&
               (allocation.verified_source_user_uuid || @legacy_bindings_by_allocation[allocation.id]&.source_user_uuid) == row.fetch("source_user_uuid") &&
               hours(allocation.regular_hours) == hours(row.fetch("regular_hours")) &&
               hours(allocation.overtime_hours) == hours(row.fetch("overtime_hours")) &&
               checks.any? { |check| check.fetch("payroll_item_id").to_i == item.id }
          raise Error, "Finalized AIRE batch entry #{row.fetch('source_time_entry_id')} changed"
        end
        @verified_finalized_allocations << allocation
      end
      unless (@legacy_bindings_by_allocation.keys - @verified_finalized_allocations.map(&:id)).empty?
        raise Error, "Legacy binding is outside the manifest's finalized payable lines"
      end
      item_ids = finalized_batch_entries.map { |row| row.fetch("payroll_item_id").to_i }.uniq
      existing_ids = TimeTrackingEntryAllocation.where(payroll_item_id: item_ids).pluck(:id).sort
      unless existing_ids == @verified_finalized_allocations.map(&:id).sort
        raise Error, "Finalized batch manifest must cover every exact payable line on its delivered checks"
      end
    end

    def live_entry(period, uuid, entry_id)
      review = review_for(period)
      employee = Array(review["employees"]).find { |row| row["source_user_uuid"].to_s.downcase == uuid }
      Array(employee&.fetch("adjustments", [])).find { |row| row["source_time_entry_id"].to_s == entry_id.to_s }
    end

    def review_for(period)
      @reviews[period.id] ||= @client.payroll_cockpit_manual_review(
        start_date: period.start_date.iso8601, end_date: period.end_date.iso8601,
        external_pay_period_id: period.id
      )
    end

    def ignored_source_entry_count
      covered = manifest_source_entry_keys
      visible = checks.map { |row| row.fetch("pay_period_id").to_i }.uniq.each_with_object(Set.new) do |period_id, keys|
        period = @company.pay_periods.find(period_id)
        Array(review_for(period)["employees"]).each do |employee|
          uuid = TimeTrackingEmployeeMapping.normalize_uuid(employee["source_user_uuid"])
          Array(employee["adjustments"]).each do |adjustment|
            keys << [ uuid, adjustment.fetch("source_time_entry_id").to_s ]
          end
        end
      end
      (visible - covered).length
    end

    def manifest_source_entry_keys
      rows = entries + finalized_batch_entries + classification_cases.flat_map do |row|
        row.fetch("source_entries").map do |entry|
          entry.merge("source_user_uuid" => row.fetch("source_user_uuid"))
        end
      end
      rows.each_with_object(Set.new) do |row, keys|
        keys << [
          TimeTrackingEmployeeMapping.normalize_uuid(row.fetch("source_user_uuid")),
          row.fetch("source_time_entry_id").to_s
        ]
      end
    end

    def apply_identities!
      identities.each do |row|
        uuid = row.fetch("source_user_uuid").downcase
        mapping = @source.time_tracking_employee_mappings.find_by(source_user_id: row.fetch("source_user_id").to_s)
        if mapping
          mapping.update!(source_user_uuid: uuid) if mapping.source_user_uuid.blank?
        else
          @source.time_tracking_employee_mappings.create!(company: @company,
            employee_id: row.fetch("employee_id"), source_user_id: row.fetch("source_user_id").to_s,
            source_user_uuid: uuid)
        end
      end
    end

    def apply_deliveries!
      checks.each do |row|
        item = PayrollItem.find(row.fetch("payroll_item_id"))
        next if item.check_events.deliveries.where(check_number: item.check_number).exists?

        item.check_events.create!(user: actor, event_type: "delivered", check_number: item.check_number,
          effective_on: Date.iso8601(row.fetch("delivered_on")), evidence_type: "hand_delivery",
          reason: "Owner-attested historical check delivery; exact AIRE reconciliation rollout",
          details: { attested: true, rollout: true })
      end
    end

    def apply_classification_cases!
      classification_cases.each do |row|
        item = PayrollItem.find(row.fetch("payroll_item_id"))
        TimeTracking::HistoricalClassificationReconciliationService.new(
          pay_period: item.pay_period, source: @source, actor: actor,
          expected_source_entry_ids: row.fetch("source_time_entry_ids"),
          before_source_entry: method(:pace_source_entry!)
        ).call(payroll_item_id: item.id, source_user_uuid: row.fetch("source_user_uuid"))
      end
    end

    def apply_exact_entries!
      entries.each do |row|
        item = PayrollItem.find(row.fetch("payroll_item_id"))
        existing = TimeTrackingManualAllocation.where(time_tracking_source: @source,
          source_time_entry_id: row.fetch("source_time_entry_id").to_s, payroll_item: item).where.not(status: "voided").first
        next if existing&.status == "issued"

        pace_source_entry!
        if existing
          TimeTracking::ManualAllocationService.new(
            pay_period: item.pay_period, source: @source, actor: actor
          ).sync!(existing, raise_on_failure: true)
          raise Error, "AIRE entry #{row.fetch('source_time_entry_id')} did not reach paid status" unless existing.reload.status == "issued"

          next
        end

        adjustment = @live_entries.fetch(row.fetch("source_time_entry_id").to_s)
        allocation = TimeTracking::ManualAllocationService.new(
          pay_period: item.pay_period, source: @source, actor: actor
        ).create!(payroll_item_id: item.id,
          source_time_entry_id: row.fetch("source_time_entry_id"),
          source_time_entry_version: adjustment.fetch("source_time_entry_version"),
          source_user_uuid: row.fetch("source_user_uuid"),
          regular_hours: row.fetch("regular_hours"), overtime_hours: row.fetch("overtime_hours"),
          original_work_date: row.fetch("original_work_date"),
          note: row["reconciliation_note"].presence || "Verified issued-check AIRE history rollout; check #{item.check_number} delivered #{checks.find { |check| check.fetch('payroll_item_id').to_i == item.id }.fetch('delivered_on')}")
        raise Error, "AIRE entry #{row.fetch('source_time_entry_id')} did not reach paid status" unless allocation.status == "issued"
      end
    end

    def finalized_acknowledgements
      item_ids = @verified_finalized_allocations.map(&:payroll_item_id).uniq
      AirePayrollEntryAcknowledgement.where(payroll_item_id: item_ids, status: "payment_issued")
    end

    def finalized_line_keys(rows)
      rows.map { |row| [ row.payroll_item_id, row.source_time_entry_id, row.respond_to?(:source_line_key) ? row.source_line_key : row.line_key ] }.sort
    end

    def apply_finalized_batch_payments!
      acknowledgements = finalized_acknowledgements
      unless finalized_line_keys(acknowledgements.to_a) == finalized_line_keys(@verified_finalized_allocations)
        raise Error, "Finalized AIRE batch payment events were not created from the verified exact payable lines"
      end
      acknowledgements.find_each do |acknowledgement|
        AirePayrollEntryStatusSyncJob.perform_now(acknowledgement.id) unless acknowledgement.delivered_at
      end
    end

    def verify_applied!
      expected = entries + classification_cases.flat_map do |row|
        row.fetch("source_entries").map { |entry| entry.merge("payroll_item_id" => row.fetch("payroll_item_id"), "source_user_uuid" => row.fetch("source_user_uuid")) }
      end
      unless expected.all? { |row| TimeTrackingManualAllocation.exists?(time_tracking_source: @source,
        payroll_item_id: row.fetch("payroll_item_id"), source_time_entry_id: row.fetch("source_time_entry_id").to_s,
        source_user_uuid: row.fetch("source_user_uuid"), regular_hours: coverage_hours(row.fetch("regular_hours")),
        overtime_hours: coverage_hours(row.fetch("overtime_hours")), original_work_date: row.fetch("original_work_date"),
        status: "issued", **(row.key?("reconciliation_note") ? { reconciliation_note: row.fetch("reconciliation_note").strip } : {}),
        **(row["source_time_entry_version"].nil? ? {} : { source_time_entry_version: row["source_time_entry_version"] })) }
        raise Error, "Not all verified AIRE entries have issued payment evidence"
      end
      unless finalized_line_keys(finalized_acknowledgements.where.not(delivered_at: nil).to_a) ==
             finalized_line_keys(@verified_finalized_allocations)
        raise Error, "Not all finalized AIRE batch payable lines reached paid status"
      end
    end

    def unique?(values)
      values.uniq.length == values.length
    end

    def pace_source_entry!
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      sleep([ @next_source_entry_at.to_f - now, 0 ].max)
      @next_source_entry_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SOURCE_ENTRY_INTERVAL_SECONDS
    end

    def hours(value)
      BigDecimal(value.to_s).round(2)
    end

    def money(value)
      BigDecimal(value.to_s).round(2)
    end
  end
end
