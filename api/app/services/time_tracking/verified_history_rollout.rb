# frozen_string_literal: true

require "digest"
require "json"
require "openssl"
require "base64"

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
      validate_identities!
      validate_checks!
      validate_entries!
      validate_finalized_batch_entries!
      {
        identity_links: identities.length,
        delivered_checks: checks.length,
        exact_entries: entries.length,
        historical_classification_cases: classification_cases.length,
        finalized_batch_entries: finalized_batch_entries.length,
        new_source_entries_ignored: @reviews.values.sum do |review|
          Array(review["employees"]).sum { |employee| Array(employee["adjustments"]).length }
        end - @live_entries.length
      }
    end

    def apply!
      summary = preview!
      apply_identities!
      apply_deliveries!
      apply_classification_cases!
      apply_exact_entries!
      apply_finalized_batch_payments!
      verify_applied!
      AireVerifiedHistoryRolloutReceipt.find_or_create_by!(manifest_sha256: @manifest_sha256) do |receipt|
        receipt.company = @company
        receipt.time_tracking_source = @source
        receipt.identity_count = identities.length
        receipt.paid_source_entry_count = entries.length +
          classification_cases.sum { |row| row.fetch("source_time_entry_ids").length } + finalized_batch_entries.length
        receipt.completed_at = Time.current
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
      raise Error, "AIRE rollout source entries contain duplicates" unless unique?(entries.map { |row| row.fetch("source_time_entry_id") })
      raise Error, "AIRE rollout finalized-batch entries contain duplicates" unless unique?(finalized_batch_entries.map { |row| row.fetch("source_time_entry_id") })
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
    rescue KeyError
      raise Error, "AIRE rollout manifest has an incomplete record"
    end

    def validate_company!
      @company = Company.find_by(id: manifest.fetch("company_id"))
      raise Error, "AIRE rollout company changed" unless @company&.name == manifest.fetch("company_name")
      @source = @company.time_tracking_sources.find_by(id: manifest.fetch("source_id"))
      raise Error, "AIRE rollout source changed" unless @source&.active? && @source.source_type == "aire_services"
      raise Error, "AIRE rollout actor cannot administer this company" unless actor.payroll_access_allowed? &&
        actor.organization_id == @company.organization_id
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
        remote = @client.payroll_cockpit_employees(employee_id: source_id).fetch("employees")
        unless remote.one? && remote.first["id"].to_s == source_id &&
               remote.first["payroll_integration_id"].to_s.downcase == uuid
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
          source_time_entry_id: row.fetch("source_time_entry_id").to_s).where.not(status: "voided").first
        if existing
          unless existing.payroll_item_id == item.id && existing.source_user_uuid == uuid &&
                 hours(existing.regular_hours) == hours(row.fetch("regular_hours")) &&
                 hours(existing.overtime_hours) == hours(row.fetch("overtime_hours"))
            raise Error, "AIRE entry #{row.fetch('source_time_entry_id')} has conflicting payment evidence"
          end
          next
        end
        adjustment = live_entry(item.pay_period, uuid, row.fetch("source_time_entry_id"))
        unless adjustment && adjustment["original_work_date"] == row.fetch("original_work_date") &&
               hours(adjustment["regular_hours"]) == hours(row.fetch("regular_hours")) &&
               hours(adjustment["overtime_hours"]) == hours(row.fetch("overtime_hours")) &&
               (row["category_name"].nil? || adjustment.dig("category", "name") == row["category_name"]) &&
               adjustment["source_time_entry_version"].is_a?(Integer)
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
      finalized_batch_entries.each do |row|
        item = PayrollItem.find_by(id: row.fetch("payroll_item_id"))
        allocation = TimeTrackingEntryAllocation.includes(:time_tracking_import).find_by(
          payroll_item_id: item&.id,
          source_time_entry_id: row.fetch("source_time_entry_id").to_s
        )
        unless item && allocation && allocation.time_tracking_import.finalized_batch? &&
               allocation.time_tracking_source_id == @source.id &&
               allocation.source_user_uuid == row.fetch("source_user_uuid") &&
               hours(allocation.regular_hours) == hours(row.fetch("regular_hours")) &&
               hours(allocation.overtime_hours) == hours(row.fetch("overtime_hours")) &&
               checks.any? { |check| check.fetch("payroll_item_id").to_i == item.id }
          raise Error, "Finalized AIRE batch entry #{row.fetch('source_time_entry_id')} changed"
        end
      end
    end

    def live_entry(period, uuid, entry_id)
      review = (@reviews[period.id] ||= @client.payroll_cockpit_manual_review(
        start_date: period.start_date.iso8601, end_date: period.end_date.iso8601,
        external_pay_period_id: period.id
      ))
      employee = Array(review["employees"]).find { |row| row["source_user_uuid"].to_s.downcase == uuid }
      Array(employee&.fetch("adjustments", [])).find { |row| row["source_time_entry_id"].to_s == entry_id.to_s }
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
          note: "Verified issued-check AIRE history rollout; check #{item.check_number} delivered #{checks.find { |check| check.fetch('payroll_item_id').to_i == item.id }.fetch('delivered_on')}")
        raise Error, "AIRE entry #{row.fetch('source_time_entry_id')} did not reach paid status" unless allocation.status == "issued"
      end
    end

    def apply_finalized_batch_payments!
      item_ids = finalized_batch_entries.map { |row| row.fetch("payroll_item_id").to_i }.uniq
      acknowledgements = AirePayrollEntryAcknowledgement.where(payroll_item_id: item_ids, status: "payment_issued")
      expected_ids = finalized_batch_entries.map { |row| row.fetch("source_time_entry_id").to_s }.sort
      unless acknowledgements.pluck(:source_time_entry_id).sort == expected_ids
        raise Error, "Finalized AIRE batch payment events were not created from the verified check deliveries"
      end
      acknowledgements.find_each do |acknowledgement|
        AirePayrollEntryStatusSyncJob.perform_now(acknowledgement.id) unless acknowledgement.delivered_at
      end
    end

    def verify_applied!
      expected = entries.map { |row| row.fetch("source_time_entry_id").to_s } +
        classification_cases.flat_map { |row| row.fetch("source_time_entry_ids").map(&:to_s) }
      issued = TimeTrackingManualAllocation.where(time_tracking_source: @source,
        source_time_entry_id: expected, status: "issued").pluck(:source_time_entry_id)
      raise Error, "Not all verified AIRE entries have issued payment evidence" unless issued.sort == expected.sort
      finalized_ids = finalized_batch_entries.map { |row| row.fetch("source_time_entry_id").to_s }.sort
      delivered = AirePayrollEntryAcknowledgement.where(
        payroll_item_id: finalized_batch_entries.map { |row| row.fetch("payroll_item_id") },
        status: "payment_issued"
      ).where.not(delivered_at: nil).pluck(:source_time_entry_id).sort
      raise Error, "Not all finalized AIRE batch entries reached paid status" unless delivered == finalized_ids
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
