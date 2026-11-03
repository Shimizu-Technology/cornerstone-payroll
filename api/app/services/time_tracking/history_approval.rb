# frozen_string_literal: true

module TimeTracking
  # All remote operations here are authenticated reads. Only mappings, optional
  # earning choices, the accounting receipt and the review audit are written.
  class HistoryApproval
    class Error < StandardError; end
    class Changed < Error
      attr_reader :changes
      def initialize(changes)
        @changes = changes
        super("History changed since this summary: #{changes.join('; ')}. Nothing was applied. Refresh the summary.")
      end
    end

    ATTESTATION = "I reviewed this history summary, employee matches, pending items and signed rounding differences. I approve accounting coverage only; this authorizes no payment of pending or owed hours."
    REVIEW_REASON = "Accountant reviewed the exact one-summary historical accounting evidence"
    REVIEW_EVIDENCE = "Authenticated AIRE history, immutable batch evidence and linked committed Payroll register; one-summary attestation"
    PENDING_TYPES = %w[pending_review pending_overtime historical_baseline_pending_overtime payment_evidence_pending].freeze
    SUMMARY_LABELS = {
      "historical_baseline" => "Hours already represented in manual payroll",
      "legacy_frozen_batch_baseline" => "Older manual payroll — verified using less detailed frozen records",
      "historical_baseline_pending_overtime" => "Regular hours represented; overtime remains pending",
      "pending_overtime" => "Overtime awaiting approval — kept pending",
      "pending_review" => "Awaiting accounting review — approval unchanged",
      "owed" => "Owed hours — still need explicit routing",
      "not_payable" => "Denied time — excluded from pay",
      "no_payable_hours" => "No payable hours",
      "payment_evidence_pending" => "Reported as paid; evidence still needed — no new payment"
    }.freeze

    def self.allowed?(actor, company)
      actor && company && (actor.organization_admin? || actor.accountant?) &&
        StaffRolePolicy.allowed?(actor, :payroll_operations, company: company) &&
        StaffRolePolicy.historical_reconciliation_allowed?(actor, company) &&
        (actor.organization_admin? || CompanyAssignment.active_access.exists?(company: company, user: actor))
    end

    def initialize(source:, actor:)
      @source, @actor, @company = source, actor, source.company
    end

    def prepare!(mapping_selections: [])
      @batch_cache = {}
      validate_context!
      existing = AireHistoryReview.where(time_tracking_source: @source, company: @company).where.not(approved_at: nil).order(:id).last
      return response(existing) if existing

      data = capture(mapping_selections: mapping_selections)
      review = AireHistoryReview.create!(company: @company, time_tracking_source: @source, actor: @actor,
        snapshot: data.fetch(:snapshot), summary: data.fetch(:summary), digest: checksum(data.fetch(:snapshot)))
      response(review)
    rescue KeyError, TypeError, ArgumentError => error
      raise Error, "AIRE history evidence is incomplete: #{error.message}"
    end

    def approve!(review:, digest:, attestation:, confirmed_mapping_uuids: [], solo_choices: [])
      @batch_cache = {}
      raise Error, "Tick the history attestation before approving" unless attestation == ATTESTATION
      unless review.company_id == @company.id && review.time_tracking_source_id == @source.id && review.actor_id == @actor.id &&
          digest == review.digest
        raise Error, "This history summary belongs to a different client, source, operator or revision"
      end
      @company.with_lock do
        # Run SHARE locks precede the source lock, as calendar publication locks
        # its run before its source. SHARE remains compatible with import FKs.
        @company.pay_periods.order(:id).lock("FOR SHARE").load
        @company.payroll_items.order(:id).lock.load
        @company.employees.order(:id).lock("FOR SHARE").load
        @actor = User.lock("FOR SHARE").find(@actor.id)
        @company.company_assignments.where(user: @actor).lock("FOR SHARE").load
        @source.lock!
        review.lock!
        validate_context!
        raise Error, "This summary was already approved" if review.approved_at
        if AireHistoryReview.where(time_tracking_source: @source).where.not(id: review.id).where.not(approved_at: nil).exists?
          raise Error, "Another summary was approved. Refresh to see the recorded approval"
        end
        raise Error, "This summary expired. Refresh the history before approving" if review.created_at < 1.hour.ago
        raise Error, "The saved summary digest differs; refresh before approving" unless checksum(review.snapshot) == review.digest

        fresh = capture(mapping_selections: review.snapshot.fetch("mapping_selections"))
        changes = changed_sections(review.snapshot, fresh.fetch(:snapshot))
        raise Changed, changes if changes.any?
        raise Error, "History coverage is incomplete: #{fresh[:summary]['blockers'].join('; ')}" unless fresh[:summary]["history_coverage_verified"]
        required = fresh[:summary]["mappings"].select { |row| row["confirmation_required"] }.map { |row| row.fetch("source_user_uuid") }
        unless (required - Array(confirmed_mapping_uuids)).empty?
          raise Error, "Explicitly confirm every employee match that is not exact"
        end
        persist_mappings!
        persist_solo_choices!(solo_choices)
        # Rebuild acknowledgements with the newly saved mapping IDs. The actor
        # attests the same visible identities/totals; no client packet is trusted.
        approved = capture(mapping_selections: review.snapshot.fetch("mapping_selections"))
        raise Error, "Fresh history coverage is incomplete; nothing was applied" unless approved[:summary]["history_coverage_verified"]
        # JSONB does not preserve hash insertion order. Canonical bytes keep
        # the approved packet digest reproducible from its immutable record.
        packet = CanonicalPayload.canonicalize(approved.fetch(:packet))
        assert_accounting_only!(packet)
        rollout = VerifiedHistoryRollout.new(manifest: packet, actor: @actor, batch_cache: @batch_cache)
        packet_digest = Digest::SHA256.hexdigest(JSON.generate(packet))
        rollout.apply!(accepted_manifest_sha256: packet_digest, release_owner: @actor.email)
        rollout.ensure_complete!
        # Catch drift after apply's own reads as well, before committing any
        # local result. The immutable snapshot identifies each changed entry.
        last = capture(mapping_selections: review.snapshot.fetch("mapping_selections"))
        raise Changed, [ "Payroll evidence or AIRE directory changed during approval" ] unless
          approved[:snapshot]["local"] == last[:snapshot]["local"] && approved[:snapshot]["directory"] == last[:snapshot]["directory"]
        unless last[:summary]["history_coverage_verified"] && accounting_projection(last[:summary]) == accounting_projection(approved[:summary])
          raise Changed, [ "source evidence or committed payroll changed during approval" ]
        end
        original_entries = review.snapshot.fetch("entry_checksums")
        raise Changed, [ "AIRE source entries changed during approval" ] unless original_entries == last[:snapshot]["entry_checksums"]
        receipt = AireVerifiedHistoryRolloutReceipt.find_by!(time_tracking_source: @source, manifest_sha256: packet_digest, coverage_verified: true)
        review.update!(approved_at: Time.current, attestation: ATTESTATION, approved_packet: packet, receipt: receipt)
        AuditLog.record!(user: @actor, company_id: @company.id, organization_id: @company.organization_id,
          action: "aire_history#approved", record_type: "AireHistoryReview", record_id: review.id, event_category: "payroll",
          metadata: { summary_digest: review.digest, packet_digest: packet_digest, receipt_id: receipt.id,
            packet_digest_contract: "canonical_payload_v1",
            approved_at: review.approved_at.iso8601(6), attestation: ATTESTATION })
        response(review)
      end
    rescue KeyError, TypeError, ArgumentError => error
      raise Error, "AIRE history evidence is incomplete: #{error.message}"
    end

    private

    def validate_context!
      raise Error, "Organization admin or assigned payroll accountant access required" unless self.class.allowed?(User.find(@actor.id), @company.reload)
      unless TestWorkspaceAccessPolicy.allowed?(user: @actor, company: @company, request_method: "POST", capability: :manage_historical_time_reconciliation)
        raise Error, "This workspace does not allow historical approval"
      end
      unless @source.active? && @source.source_type == "aire_services" && @source.remote_identity_pinned?
        raise Error, "An active AIRE source with a verified installation is required"
      end
      if @source.aire_payroll_calendar_periods.exists?
        raise Error, "History approval is available only before any calendar is published or prepared"
      end
      boundary = @source.cutoff_enforcement_starts_on
      raise Error, "Choose the first connected period before reviewing history" unless boundary
      @through = boundary - 1.day
      unless @company.pay_periods.where(status: "committed", cycle: "regular", run_purpose: "regular", end_date: @through).exists?
        raise Error, "Commit the manual payroll ending #{@through} before reviewing history"
      end
    end

    def capture(mapping_selections:)
      @client = Client.for_payroll_actor(@source, actor: @actor)
      directory = directory_entries
      @directory = directory.index_by { |row| row.fetch("payroll_integration_id") }
      @employees = @company.employees.includes(:employee_wage_rates).order(:id).to_a
      @saved_mappings = @source.time_tracking_employee_mappings.order(:id).to_a
      @saved_mapping_fingerprint = checksum(@saved_mappings.map(&:attributes))
      base = { "version" => 1, "company_id" => @company.id, "company_name" => @company.name,
        "source_id" => @source.id, "source_instance_id" => @source.expected_source_instance_id, "actor_id" => @actor.id,
        "history_through_work_date" => @through.iso8601, "identity_links" => [], "delivered_checks" => [],
        "issued_entries" => [], "classification_cases" => [], "finalized_batch_entries" => [] }
      export = VerifiedHistoryRollout.new(manifest: base, actor: @actor, batch_cache: @batch_cache)
      packet = export.capture_review_packet!
      inventory = export.captured_history_entries
      @mappings, mapping_rows, mapping_blockers = plan_mappings(inventory, mapping_selections)
      bindings = exact_component_bindings(packet.fetch("rounding_review_blockers"))
      verifier = HistoryDispositionVerifier.new(source: @source, company: @company, actor: @actor, client: @client,
        employee_mappings: @mappings, component_bindings: bindings, batch_cache: @batch_cache)
      verifier.discover_rounding_variances!(inventory)
      # Discovery may first have lacked a new mapping. Repeat with the proposed
      # mappings to obtain authenticated component dimensions before binding.
      bindings = (bindings + exact_component_bindings(verifier.rounding_review_blockers)).uniq
      verifier = HistoryDispositionVerifier.new(source: @source, company: @company, actor: @actor, client: @client,
        employee_mappings: @mappings, component_bindings: bindings, batch_cache: @batch_cache)
      verifier.discover_rounding_variances!(inventory)
      variances = verifier.rounding_variances
      acknowledgements = variances.select { |row| row["within_limit"] }.map do |row|
        row.except("within_limit", "acknowledged").merge(review_fields("accountant_reviewed_rounding_variance"))
      end
      verifier = HistoryDispositionVerifier.new(source: @source, company: @company, actor: @actor, client: @client,
        employee_mappings: @mappings, component_bindings: bindings, rounding_acknowledgements: acknowledgements, batch_cache: @batch_cache)
      verifier.discover_rounding_variances!(inventory)
      blockers = mapping_blockers.dup
      dispositions = inventory.map do |entry|
        draft = packet.fetch("reviewed_dispositions").find { |row| row["source_time_entry_id"] == entry.fetch("id") }
          .merge("reason" => REVIEW_REASON, "evidence" => REVIEW_EVIDENCE)
        types = %w[historical_baseline legacy_frozen_batch_baseline pending_overtime historical_baseline_pending_overtime owed not_payable no_payable_hours payment_evidence_pending pending_review]
        type = types.find { |candidate| verifier.verified?(draft.merge("disposition" => candidate), entry) }
        blockers << "Entry #{entry.fetch('id')}: source evidence does not support a complete accounting disposition" unless type
        draft.merge("disposition" => type || "pending_review")
      end
      packet.merge!("reviewed_dispositions" => dispositions, "rounding_variance_acknowledgements" => acknowledgements,
        "historical_earning_component_bindings" => bindings, "rounding_variances" => variances, "rounding_review_blockers" => [])
      result = VerifiedHistoryRollout.new(manifest: packet, actor: @actor, employee_mappings: @mappings, batch_cache: @batch_cache).preview!
      blockers.concat(result[:rounding_review_blockers].map { |row| row.fetch("reason") })
      blockers << "A signed rounding difference exceeds 0.05 hours" if variances.any? { |row| !row["within_limit"] }
      coverage = result.fetch(:history_coverage_verified) && blockers.empty?
      details = dispositions.map do |row|
        entry = inventory.find { |record| record.fetch("id") == row.fetch("source_time_entry_id") }
        remote = @directory[row.fetch("source_user_uuid")]
        { "id" => entry.fetch("id"), "employee" => remote&.fetch("full_name"), "work_date" => entry.fetch("work_date"),
          "hours" => entry.fetch("hours").to_s, "disposition" => row.fetch("disposition"), "approval_status" => entry.dig("state", "approval_status"),
          "category" => entry.dig("category", "name"),
          "pending_hours" => row["disposition"] == "historical_baseline_pending_overtime" ?
            (BigDecimal(entry.fetch("hours").to_s) - entry.dig("history_evidence", "baseline_lines").sum { |line| BigDecimal(line.fetch("total_hours").to_s) }).to_s("F") : entry.fetch("hours").to_s }
      end
      summary = { "history_coverage_verified" => coverage, "through_work_date" => @through.iso8601,
        "source_name" => @source.name, "mappings" => mapping_rows,
        "dispositions" => details.group_by { |row| row.fetch("disposition") }.map do |type, rows|
          { "type" => type, "label" => SUMMARY_LABELS.fetch(type), "count" => rows.length,
            "hours" => rows.sum { |row| BigDecimal(row.fetch("hours")) }.to_s("F") }
        end,
        "rounding_variances" => variances.map { |row| row.merge("employee" => @employees.find { |employee| employee.id == row["employee_id"] }&.full_name) },
        "owed" => details.select { |row| row["disposition"] == "owed" },
        "pending_review" => details.select { |row| PENDING_TYPES.include?(row["disposition"]) }.map { |row| row.merge("hours" => row.fetch("pending_hours")) },
        "blockers" => blockers.uniq, "solo_decisions" => solo_decisions(inventory), "attestation" => ATTESTATION }
      snapshot = { "entry_checksums" => inventory.sort_by { |row| row.fetch("id") }.to_h { |row| [ row.fetch("id"), checksum(row) ] },
        "entry_observations" => inventory.to_h { |row| [ row.fetch("id"), row.slice("version", "hours", "work_date", "source_user_uuid", "state", "category") ] },
        "directory" => checksum(directory.map { |row| row.slice("id", "payroll_integration_id", "full_name", "email", "active", "role") }), "local" => local_fingerprint(inventory),
        "mapping_selections" => mapping_rows.map { |row| row.slice("source_user_uuid", "employee_id") },
        "summary" => accounting_projection(summary) }
      { packet: packet, snapshot: snapshot, summary: summary }
    end

    def directory_entries
      rows = []
      page = 1
      count = pages = nil
      loop do
        response = @client.payroll_cockpit_employees(page: page, per_page: 100)
        metadata = response.fetch("pagination")
        entries = response.fetch("employees")
        count ||= metadata.fetch("total_count")
        pages ||= metadata.fetch("total_pages")
        unless entries.is_a?(Array) && count.is_a?(Integer) && count >= 0 && pages.is_a?(Integer) && pages.between?(1, 100) &&
            metadata["current_page"] == page && metadata["total_count"] == count && metadata["total_pages"] == pages &&
            metadata["per_page"] == 100 && pages == [ (count + 99) / 100, 1 ].max &&
            entries.length == [ 100, count - (page - 1) * 100 ].min && metadata["truncated"] == (page < pages)
          raise Error, "AIRE employee directory changed or is incomplete"
        end
        rows.concat(entries)
        break if page == pages
        page += 1
      end
      unless rows.all? { |row| row.is_a?(Hash) && row["id"].to_s.match?(/\A[1-9]\d*\z/) && row["payroll_integration_id"].to_s.match?(TimeTrackingSource::UUID_PATTERN) && row["full_name"].present? } &&
          rows.map { |row| row["id"] }.uniq.length == rows.length && rows.map { |row| row["payroll_integration_id"] }.uniq.length == rows.length
        raise Error, "AIRE employee directory has missing or conflicting permanent identities"
      end
      rows.sort_by { |row| row.fetch("id").to_i }
    end

    def plan_mappings(inventory, selections)
      raise Error, "Employee selections must be a list" unless selections.is_a?(Array) && selections.all?(Hash)
      selected = selections.index_by { |row| row.fetch("source_user_uuid") }
      raise Error, "Employee selections contain duplicates" unless selected.length == selections.length
      planned, rows, blockers = [], [], []
      inventory.group_by { |entry| entry["source_user_uuid"] }.each do |uuid, entries|
        remote = @directory[uuid]
        unless remote && entries.all? { |entry| entry.dig("employee", "id") == remote["id"] }
          blockers << "AIRE identity #{uuid.presence || '(missing)'} is absent or conflicts with its authenticated directory"
          next
        end
        saved = @saved_mappings.find { |mapping| mapping.source_user_uuid == uuid }
        numeric = @saved_mappings.find { |mapping| mapping.source_user_id == remote["id"] }
        saved ||= numeric if numeric&.source_user_uuid.blank?
        confirmed = saved&.source_user_uuid.present?
        exact = @employees.select { |employee| exact_name(employee.full_name) == exact_name(remote["full_name"]) &&
          (employee.email.blank? || remote["email"].blank? || employee.email.casecmp?(remote["email"])) }
        chosen_id = selected[uuid]&.fetch("employee_id", nil) || saved&.employee_id || (exact.one? && exact.sole.id)
        employee = @employees.find { |record| record.id == chosen_id.to_s.to_i }
        conflict = @saved_mappings.any? { |mapping| (mapping.source_user_id == remote["id"] || mapping.employee_id == employee&.id) && mapping != saved }
        if !employee || conflict || (saved && (saved.employee_id != employee.id || saved.source_user_id != remote["id"]))
          blockers << "Choose an unambiguous Payroll employee for #{remote['full_name']}"
        else
          mapping = saved || TimeTrackingEmployeeMapping.new(company: @company, time_tracking_source: @source,
            employee: employee, source_user_id: remote["id"], source_user_uuid: uuid,
            source_display_name: remote["full_name"], source_email: remote["email"])
          mapping.source_user_uuid = uuid if mapping.source_user_uuid.blank?
          planned << mapping
        end
        rows << { "source_user_uuid" => uuid, "source_user_id" => remote["id"], "source_name" => remote["full_name"],
          "employee_id" => employee&.id, "employee_name" => employee&.full_name,
          "existing" => !!confirmed, "confirmation_required" => !confirmed && (!exact.one? || exact.sole.id != employee&.id),
          "options" => @employees.map { |record| { "id" => record.id, "name" => record.full_name } } }
      end
      if planned.map(&:employee_id).uniq.length != planned.length
        blockers << "Two AIRE people cannot share one Payroll employee"
      end
      [ planned, rows, blockers ]
    end

    def exact_component_bindings(blockers)
      blockers.filter_map do |row|
        next unless row["source_category"] && row["employee_id"]
        # Never infer a Solo earning treatment, including from matching hours.
        category = row.fetch("source_category")
        next if TimeTrackingEarningChoice.solo_category?(category)
        items = @company.payroll_items.where(pay_period_id: row.fetch("run_id"), employee_id: row.fetch("employee_id")).includes(:payroll_item_earnings)
        components = items.flat_map do |item|
          earnings = item.payroll_item_earnings.select { |earning| earning.category == (row["category"] == "REG" ? "regular" : "overtime") }
          if earnings.any?
            earnings.map { |earning| [ "earning:#{earning.label}", earning.label ] }
          else
            item.wage_rate_hours.map { |rate| [ "wage_rate:#{rate['employee_wage_rate_id']}", rate["label"] ] }
          end
        end.uniq
        names = [ category["key"], category["name"] ].map { |value| normalized(value).delete_suffix(" hours") }
        matches = components.select { |_, label| names.include?(normalized(label).delete_suffix(" hours")) }
        next unless matches.one?

        row.except("reason").merge(review_fields("historical_earning_component_binding"), "earning_component" => matches.sole.first)
      end.uniq
    end

    def persist_mappings!
      @mappings.each do |mapping|
        next if mapping.persisted? && !mapping.has_changes_to_save?
        mapping.save!
        AuditLog.record!(user: @actor, company_id: @company.id, action: "time_tracking_employee_mapping#confirmed",
          record_type: "TimeTrackingEmployeeMapping", record_id: mapping.id, event_category: "payroll",
          metadata: { employee_id: mapping.employee_id, source_user_id: mapping.source_user_id, source_user_uuid: mapping.source_user_uuid })
      end
    end

    def solo_decisions(inventory)
      inventory.select { |entry| TimeTrackingEarningChoice.solo_category?(entry["category"] || {}) }
        .group_by { |entry| entry["source_user_uuid"] }.map do |uuid, entries|
        mapping = @mappings.find { |record| record.source_user_uuid == uuid }
        employee = @employees.find { |record| record.id == mapping&.employee_id }
        { "source_user_uuid" => uuid, "employee_id" => employee&.id, "employee" => employee&.full_name,
          "hours" => entries.sum { |entry| BigDecimal(entry.fetch("hours").to_s) }.to_s("F"),
          "options" => employee ? employee.active_wage_rates.filter_map do |rate|
            { "id" => rate.id, "label" => rate.label, "rate" => rate.rate.to_s } if rate.rate&.positive?
          end : [] }
      end
    end

    def persist_solo_choices!(choices)
      raise Error, "Solo choices must be a list" unless choices.is_a?(Array) && choices.all?(Hash)
      raise Error, "Solo choices contain duplicates" unless choices.map { |row| row["employee_id"] }.uniq.length == choices.length
      choices.each do |row|
        next if row["employee_wage_rate_id"].blank?
        mapping = @mappings.find { |record| record.employee_id == row["employee_id"].to_i }
        rate = mapping && EmployeeWageRate.active.find_by(employee_id: mapping.employee_id, id: row["employee_wage_rate_id"])
        raise Error, "The selected Solo earning component or rate is no longer available for this employee" unless rate&.rate&.positive?
        choice = TimeTrackingEarningChoice.find_or_initialize_by(time_tracking_source: @source, employee_id: mapping.employee_id, source_category_key: "solo")
        choice.update!(employee_wage_rate: rate, reviewed_by: @actor,
          rate_snapshot: rate.attributes.slice("id", "employee_id", "label", "rate", "active").as_json)
        AuditLog.record!(user: @actor, company_id: @company.id, action: "time_tracking_earning_choice#confirmed",
          record_type: "TimeTrackingEarningChoice", record_id: choice.id, event_category: "payroll",
          metadata: { employee_id: mapping.employee_id, employee_wage_rate_id: rate.id, source_category_key: "solo", rate: rate.rate.to_s })
      end
    end

    def local_fingerprint(inventory)
      run_ids = inventory.flat_map { |entry| entry.dig("history_evidence", "baseline_lines").to_a.map { |line| line.dig("processing", "external_pay_period_id") } }.compact.uniq
      { "source" => checksum(@source.attributes.except("shared_secret", "last_synced_at", "updated_at")),
        "boundary" => @source.cutoff_enforcement_starts_on.iso8601,
        "company" => checksum(@company.attributes),
        "mappings" => @saved_mapping_fingerprint,
        "employees" => checksum(@employees.map { |employee| [ employee.attributes, employee.employee_wage_rates.sort_by(&:id).map(&:attributes) ] }),
        "runs" => @company.pay_periods.where(id: run_ids).order(:id).to_h do |run|
          items = run.payroll_items.includes(:payroll_item_earnings).order(:id)
          [ run.id.to_s, checksum([ run.attributes, items.map { |item| [ item.attributes, item.payroll_item_earnings.sort_by(&:id).map(&:attributes) ] } ]) ]
        end }
    end

    def changed_sections(before, after)
      changes = []
      ids = (before.fetch("entry_checksums").keys | after.fetch("entry_checksums").keys).select { |id| before["entry_checksums"][id] != after["entry_checksums"][id] }
      if ids.any?
        changes << "AIRE entries #{ids.join(', ')} changed, appeared or disappeared"
        ids.each do |id|
          old = before.fetch("entry_observations").fetch(id, {})
          current = after.fetch("entry_observations").fetch(id, {})
          (old.keys | current.keys).each do |field|
            changes << "Entry #{id} #{field}: #{old[field].inspect} → #{current[field].inspect}" if old[field] != current[field]
          end
        end
      end
      changes << "AIRE employee directory changed" if before["directory"] != after["directory"]
      before.fetch("local").each do |key, value|
        next if after.fetch("local")[key] == value
        if key == "runs"
          current = after.fetch("local").fetch("runs")
          changed_ids = (value.keys | current.keys).select { |id| value[id] != current[id] }
          changes << "Payroll runs #{changed_ids.join(', ')} changed"
        else
          changes << "Payroll #{key} changed"
        end
      end
      changes << "Accounting summary changed" if before["summary"] != after["summary"]
      changes
    end

    def accounting_projection(summary)
      summary.except("solo_decisions").deep_dup.tap do |value|
        value["rounding_variances"] = value["rounding_variances"].map { |row| row.except("employee_mapping_id", "employee_mapping_checksum", "acknowledged") }
        value["mappings"] = value["mappings"].map { |row| row.except("existing", "confirmation_required") }
      end
    end

    def assert_accounting_only!(packet)
      unless %w[delivered_checks issued_entries classification_cases finalized_batch_entries legacy_identity_bindings].all? { |key| packet.fetch(key, []).empty? }
        raise Error, "One-summary approval cannot issue payments, allocations or source acknowledgements"
      end
    end

    def review_fields(type)
      { "type" => type, "reviewer_id" => @actor.id, "reason" => REVIEW_REASON, "evidence" => REVIEW_EVIDENCE }
    end

    def response(review)
      review.summary.merge("review_id" => review.id, "digest" => review.digest,
        "approved_at" => review.approved_at&.iso8601(6), "approved_by" => review.approved_at && review.actor.name)
    end

    def normalized(value)
      value.to_s.unicode_normalize(:nfc).downcase.gsub(/[^\p{Alnum}]+/u, " ").squish
    end

    def exact_name(value)
      value.to_s.unicode_normalize(:nfc).downcase.squish
    end

    def checksum(value)
      CanonicalPayload.checksum(value.as_json)
    end
  end
end
