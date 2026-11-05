# frozen_string_literal: true

# A committed connected run with one row per payment-eligibility outcome, plus a
# configurable number of ordinary paid rows. Evidence rows that real workflows
# verify elsewhere are saved without validation: this read must report them.
module PayPeriodDetailReadFixture
  ZERO_ITEM = { hours_worked: 0, overtime_hours: 0, holiday_hours: 0, pto_hours: 0, gross_pay: 0, net_pay: 0 }.freeze

  def detail_read_context
    @detail_read_context ||= begin
      company = create(:company, next_check_number: 9001)
      {
        company: company,
        department: create(:department, company: company),
        actor: create(:user, company: company, organization: company.organization),
        source: create(:time_tracking_source, company: company, source_type: "aire_services",
          expected_source_instance_id: SecureRandom.uuid, source_protocol: "shimizu_time_payroll",
          source_protocol_version: "1.0", identity_verified_at: Time.current,
          source_capabilities: TimeTracking::Connector::AIRE_CAPABILITIES + [ "payment_cancellation_v1" ])
      }
    end
  end

  def build_detail_read_period(ordinary_rows:, status: :committed, branches: true)
    context = detail_read_context
    start = next_detail_read_start
    traits = status == :committed ? [ :committed ] : []
    period = create(:pay_period, *traits, status: status.to_s, company: context[:company],
      start_date: start, end_date: start + 14.days, pay_date: start + 20.days)
    import = create(:time_tracking_import, :finalized_aire_batch, pay_period: period,
      time_tracking_source: context[:source], status: "applied",
      processed_payload: { "exclusions" => [ { "held_total_hours" => "1.5" } ] })
    state = context.merge(period: period, import: import, sequence: 0)

    ordinary_rows.times do |index|
      # Draft checks are not printed yet, so eligibility reaches the print packages.
      printed_at = status == :committed ? Time.current : nil
      index.even? ? receipted_paper_row(state, printed_at:) : earlier_receipt_paper_row(state, printed_at:)
    end
    if branches
      status == :committed ? eligibility_branch_rows(state) : pay_basis_hold_rows(state)
      correction_reference_row(state)
    end
    period
  end

  private

  def next_detail_read_start
    @detail_read_start = (@detail_read_start || Date.new(2026, 1, 1)) + 30.days
  end

  def detail_read_item(state, **attributes)
    state[:sequence] += 1
    number = "#{state[:period].id}#{state[:sequence].to_s.rjust(3, '0')}"
    create(:payroll_item, company: state[:company], pay_period: state[:period],
      employee: create(:employee, company: state[:company], department: state[:department]),
      payment_delivery_method: "paper_check", check_number: number, gross_pay: 600, net_pay: 500,
      **attributes)
  end

  def detail_read_line(state, item, uuid: SecureRandom.uuid, import: state[:import], period: state[:period], **attributes)
    state[:sequence] += 1
    TimeTrackingEntryAllocation.create!(company: state[:company], time_tracking_source: state[:source],
      time_tracking_import: import, pay_period: period, payroll_item: item, employee: item.employee,
      source_user_id: item.employee_id.to_s, source_user_uuid: uuid, source_time_entry_id: state[:sequence].to_s,
      line_key: "flight:#{state[:sequence]}", source_kind: "current", original_work_date: period.start_date,
      total_hours: 6, regular_hours: 5, overtime_hours: 1, **attributes)
  end

  # Current shape: every line has its exact prepared receipt, so eligibility
  # inspects every line before it allows the check to be retired.
  def receipted_paper_row(state, printed_at:, lines: 4)
    item = detail_read_item(state, check_printed_at: printed_at)
    lines.times { detail_read_receipt(state, item, detail_read_line(state, item)) }
    item
  end

  # Run 61's shape: entry-level receipts from before line-level tracking.
  def earlier_receipt_paper_row(state, printed_at:, lines: 4)
    item = detail_read_item(state, check_printed_at: printed_at)
    lines.times do
      line = detail_read_line(state, item)
      AirePayrollEntryAcknowledgement.create!(time_tracking_import: state[:import], payroll_item: item,
        source_event_key: SecureRandom.uuid, event_id: SecureRandom.uuid, source_time_entry_id: line.source_time_entry_id,
        source_user_id: line.source_user_id, status: "committed", occurred_at: 1.day.ago)
    end
    item
  end

  def detail_read_receipt(state, item, line, **attributes)
    AirePayrollEntryAcknowledgement.create!({ time_tracking_import: state[:import], payroll_item: item,
      source_event_key: SecureRandom.uuid, event_id: SecureRandom.uuid, source_time_entry_id: line.source_time_entry_id,
      source_line_key: line.line_key, source_user_id: line.source_user_id, source_user_uuid: line.source_user_uuid,
      contract_version: AirePayrollEntryAcknowledgement::LINE_CONTRACT_VERSION, source_kind: line.source_kind,
      total_hours: line.total_hours, regular_hours: line.regular_hours, overtime_hours: line.overtime_hours,
      payment_method: "paper_check", payment_reference: item.check_number, status: "payment_prepared",
      occurred_at: 1.hour.ago }.merge(attributes))
  end

  def detail_read_manual(state, item, **attributes)
    state[:sequence] += 1
    allocation = TimeTrackingManualAllocation.create!(company: state[:company], time_tracking_source: state[:source],
      pay_period: state[:period], payroll_item: item, employee: item.employee, created_by: state[:actor],
      source_user_uuid: SecureRandom.uuid, source_time_entry_id: state[:sequence].to_s, source_time_entry_version: 1,
      original_work_date: state[:period].start_date, regular_hours: 4, overtime_hours: 0,
      reconciliation_note: "Synthetic source hours on this committed payroll item")
    allocation.update_columns(attributes) if attributes.any?
    allocation
  end

  def detail_read_disposition(state, corrective_item:, original_allocation:, import: original_allocation.time_tracking_import)
    TimeTrackingCorrectionDisposition.new(company: state[:company], time_tracking_source: state[:source],
      time_tracking_import: import, original_allocation: original_allocation,
      corrective_payroll_item: corrective_item, created_by: state[:actor], source_instance_id: state[:source].expected_source_instance_id,
      batch_id: "synthetic", batch_checksum: "a" * 64, source_user_id: "1", source_user_uuid: SecureRandom.uuid,
      source_time_entry_id: original_allocation.source_time_entry_id, line_key: original_allocation.line_key,
      line_snapshot: { "synthetic" => true }, proof_digest: "b" * 64, reason: "Synthetic disposition evidence",
      source_kind: "correction", total_hours: -1, regular_hours: -1, overtime_hours: 0).save!(validate: false)
  end

  def detail_read_other_period(state)
    state[:sequence] += 1
    start = Date.new(2020, 1, 1) + (state[:period].id * 1000 + state[:sequence]) * 15
    create(:pay_period, :committed, company: state[:company], start_date: start, end_date: start + 14.days, pay_date: start + 20.days)
  end

  def detail_read_other_run_line(state, item)
    other_period = detail_read_other_period(state)
    other_import = create(:time_tracking_import, :finalized_aire_batch, pay_period: other_period,
      time_tracking_source: state[:source], status: "applied")
    other_item = create(:payroll_item, company: state[:company], pay_period: other_period, employee: item.employee, net_pay: 100)
    detail_read_line(state, other_item, import: other_import, period: other_period)
  end

  # Unlinked correction reference: the retained source must be reviewed.
  def correction_reference_row(state)
    source = create(:payroll_item, company: state[:company], pay_period: detail_read_other_period(state), net_pay: 10,
      employee: create(:employee, company: state[:company], department: state[:department], employment_type: "contractor", contractor_pay_type: "flat_fee"))
    detail_read_item(state, check_number: nil, timekeeping_source: "correction_reference", correction_for_payroll_item: source, employee: source.employee)
  end

  # Imported rows on an uncommitted run compare captured and current pay basis.
  def pay_basis_hold_rows(state)
    imported = { import_source: "time_tracking:aire_services", check_number: nil }
    snapshot = { "employment_type" => "hourly", "source_bucket_key" => "flight" }
    detail_read_line(state, detail_read_item(state, **imported), earning_snapshot: snapshot)
    changed = detail_read_item(state, **imported)
    detail_read_line(state, changed, earning_snapshot: snapshot)
    changed.employee.update_columns(employment_type: "salary")
    detail_read_line(state, detail_read_item(state, **imported), earning_snapshot: snapshot.except("employment_type"))
    detail_read_item(state, payment_delivery_method: "direct_deposit", check_number: nil)
    detail_read_item(state, payment_delivery_method: "paper_check")
    pending = detail_read_item(state)
    detail_read_manual(state, pending, payment_resolution_intent: { "synthetic" => true }, payment_resolution_receipt: {})
  end

  def eligibility_branch_rows(state)
    company = state[:company]
    actor = state[:actor]

    # Allowed: no blockers, with and without prior instrument activity.
    detail_read_item(state)
    detail_read_item(state, check_printed_at: Time.current)
    detail_read_item(state, check_number: nil, payment_delivery_method: "direct_deposit")

    # Bank payment confirmed.
    confirmed = detail_read_item(state, check_number: nil, payment_delivery_method: "direct_deposit")
    DirectDepositPaymentConfirmation.create!(payroll_item: confirmed, user: actor,
      settled_on: PayrollBusinessClock.today, bank_reference: "Synthetic transfer")

    # Duplicate check link.
    duplicate = detail_read_item(state)
    duplicate.mark_printed!(user: actor)
    duplicate.mark_delivered!(user: actor, delivered_on: PayrollBusinessClock.today, delivery_method: "hand_delivery", attestation: true)
    CheckSupersessionRolloutApproval.find_or_create_by!(company: company) do |approval|
      approval.assign_attributes(approved_by: create(:user, company: company, role: "org_admin"),
        reason: "Approved for isolated duplicate-link read regression", approved_at: Time.current)
    end
    duplicate_check = create(:non_employee_check, :standalone, company: company, check_type: "other",
      payment_period_type: "none", tax_year: nil, tax_month: nil, payable_to: duplicate.employee.full_name,
      amount: duplicate.net_pay, check_number: duplicate.check_number, printed_at: Time.current, payment_method: "check")
    NonEmployeeCheckSupersessionService.new(check: duplicate_check, actor: actor).supersede!(
      payroll_item_id: duplicate.id, reason: "Verified both records represent the same physical employee check",
      recipient_verified: true)

    # Pending reported-payment match.
    pending = detail_read_item(state)
    detail_read_manual(state, pending, payment_resolution_intent: { "synthetic" => true }, payment_resolution_receipt: {})
    # A completed match does not block.
    resolved = detail_read_item(state)
    detail_read_manual(state, resolved, payment_resolution_intent: { "synthetic" => true }, payment_resolution_receipt: { "ok" => true })

    # Each exact source accounting correction shape.
    corrective = detail_read_item(state)
    detail_read_disposition(state, corrective_item: corrective, original_allocation: detail_read_other_run_line(state, corrective))
    parent = detail_read_item(state)
    child = create(:payroll_item, company: company, pay_period: detail_read_other_period(state),
      employee: parent.employee, correction_for_payroll_item: parent, net_pay: 10)
    detail_read_disposition(state, corrective_item: child, original_allocation: detail_read_other_run_line(state, parent))
    original = detail_read_item(state)
    unrelated = create(:payroll_item, company: company, pay_period: detail_read_other_period(state), employee: original.employee, net_pay: 10)
    detail_read_disposition(state, corrective_item: unrelated, original_allocation: detail_read_line(state, original),
      import: detail_read_other_run_line(state, original).time_tracking_import)

    # Earlier cancellation still syncing; voided manual rows do not count.
    cancelling = detail_read_item(state)
    detail_read_manual(state, cancelling, payment_cancellation_intent: { "command_id" => "synthetic" })
    void_manual = detail_read_item(state)
    detail_read_manual(state, void_manual, status: "voided", payment_cancellation_intent: { "command_id" => "synthetic" })

    # Manual allocation counts as instrument activity, then each receipt guard.
    issued = detail_read_item(state)
    detail_read_manual(state, issued, status: "issued")
    intent = detail_read_item(state)
    detail_read_manual(state, intent, payment_issue_intent: { "synthetic" => true })
    printed_manual = detail_read_item(state, check_printed_at: Time.current)
    detail_read_manual(state, printed_manual, status: "issued")

    # Connected-source guards: inactive/unsupported source and unknown identity.
    unsupported_source = create(:time_tracking_source, company: company, source_type: "custom", active: false)
    unsupported = detail_read_item(state, check_printed_at: Time.current)
    unsupported_import = create(:time_tracking_import, pay_period: state[:period], time_tracking_source: unsupported_source, status: "applied",
      source_payload_hash: Digest::SHA256.hexdigest("unsupported-#{state[:period].id}"))
    TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: unsupported_source,
      time_tracking_import: unsupported_import, pay_period: state[:period], payroll_item: unsupported, employee: unsupported.employee,
      source_user_id: "1", source_user_uuid: SecureRandom.uuid, source_time_entry_id: "unsupported", line_key: "flight:unsupported",
      source_kind: "current", original_work_date: state[:period].start_date, total_hours: 1, regular_hours: 1, overtime_hours: 0)
    no_identity = detail_read_item(state, check_printed_at: Time.current)
    detail_read_line(state, no_identity, uuid: nil)

    # Receipt mismatches: wrong number, hours, identity, or older-than-latest.
    wrong_number = detail_read_item(state, check_printed_at: Time.current)
    detail_read_receipt(state, wrong_number, detail_read_line(state, wrong_number), payment_reference: "old-number")
    wrong_identity = detail_read_item(state, check_printed_at: Time.current)
    detail_read_receipt(state, wrong_identity, detail_read_line(state, wrong_identity), source_user_uuid: SecureRandom.uuid)
    superseded = detail_read_item(state, check_printed_at: Time.current)
    superseded_line = detail_read_line(state, superseded)
    detail_read_receipt(state, superseded, superseded_line)
    detail_read_receipt(state, superseded, superseded_line, status: "payment_issued", source_user_uuid: SecureRandom.uuid)
    latest_good = detail_read_item(state, check_printed_at: Time.current)
    latest_good_line = detail_read_line(state, latest_good)
    detail_read_receipt(state, latest_good, latest_good_line, source_user_uuid: SecureRandom.uuid)
    detail_read_receipt(state, latest_good, latest_good_line, status: "payment_issued")
    cancelled_receipt = detail_read_item(state, check_printed_at: Time.current)
    detail_read_receipt(state, cancelled_receipt, detail_read_line(state, cancelled_receipt), status: "payment_failed")

    # Corrected successor: its link's original line needs its own exact receipt.
    successor = detail_read_item(state, check_printed_at: Time.current)
    original_line = detail_read_other_run_line(state, successor)
    TimeTrackingFinancialCorrectionLink.new(original_allocation: original_line,
      predecessor_payroll_item: original_line.payroll_item, payroll_item: successor,
      command_id: SecureRandom.uuid, event_id: SecureRandom.uuid, payload: { "synthetic" => true },
      request_digest: "c" * 64).save!(validate: false)

    corrected = detail_read_item(state, check_printed_at: Time.current)
    corrected_line = detail_read_other_run_line(state, corrected)
    detail_read_receipt(state, corrected, corrected_line, time_tracking_import: corrected_line.time_tracking_import)
    TimeTrackingFinancialCorrectionLink.new(original_allocation: corrected_line,
      predecessor_payroll_item: corrected_line.payroll_item, payroll_item: corrected,
      command_id: SecureRandom.uuid, event_id: SecureRandom.uuid, payload: { "synthetic" => true },
      request_digest: "e" * 64).save!(validate: false)

    # Numeric-only line whose identity comes from approved binding evidence.
    bound = detail_read_item(state, check_printed_at: Time.current)
    bound_line = detail_read_line(state, bound, uuid: nil)
    bound_uuid = SecureRandom.uuid
    TimeTrackingLegacyIdentityBinding.new(time_tracking_entry_allocation: bound_line, company: company,
      time_tracking_source: state[:source], employee: bound.employee, approved_by: actor,
      time_tracking_employee_mapping: TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: state[:source],
        employee: bound.employee, source_user_id: bound_line.source_user_id, source_user_uuid: bound_uuid),
      source_user_uuid: bound_uuid, source_instance_id: state[:source].expected_source_instance_id,
      accepted_manifest_sha256: "f" * 64, batch_checksum: state[:import].external_batch_checksum, source_time_entry_version: 0,
      source_time_entry_id: bound_line.source_time_entry_id, source_user_id: bound_line.source_user_id,
      source_line_key: bound_line.line_key, original_work_date: bound_line.original_work_date,
      release_owner: "Synthetic owner", external_batch_id: state[:import].external_batch_id,
      source_total_hours: bound_line.total_hours).save!(validate: false)
    detail_read_receipt(state, bound, bound_line, source_user_uuid: bound_uuid)

    # Print package activity for this number, an old number, and a numberless row.
    packaged = detail_read_item(state)
    old_package = detail_read_item(state)
    numberless_package = detail_read_item(state)
    state[:period].check_print_runs.create!(company: company, created_by: actor, check_stock_type: "standard",
      storage_key: "synthetic-#{SecureRandom.uuid}", filename: "synthetic-checks.pdf", sha256: "a" * 64, byte_size: 100,
      selected_count: 3, generated_at: Time.current, manifest: [
        { "source_type" => "payroll_item", "source_id" => packaged.id, "check_number" => packaged.check_number },
        { "source_type" => "payroll_item", "source_id" => old_package.id, "check_number" => "old-number" },
        { "source_type" => "payroll_item", "source_id" => numberless_package.id }
      ])

    # Check events and clearing evidence.
    delivered = detail_read_item(state)
    delivered.check_events.create!(user: actor, event_type: "delivered", check_number: delivered.check_number, effective_on: PayrollBusinessClock.today)
    cleared = detail_read_item(state)
    CheckReconciliationEvent.create!(company: company, pay_period: state[:period], payroll_item: cleared, recorded_by: actor,
      event_type: "cleared", check_number: cleared.check_number, idempotency_key: SecureRandom.uuid,
      amount: 500, effective_on: PayrollBusinessClock.today, evidence_type: CheckReconciliationEvent::EVIDENCE_TYPES.first)

    # Voided, reversed and zero-money rows.
    detail_read_item(state, voided: true, voided_at: Time.current, void_reason: "Synthetic void reason", check_number: "void-#{state[:period].id}")
    detail_read_item(state, payroll_reversed_at: Time.current, payroll_reversed_by_id: actor.id, payroll_reversal_reason: "Synthetic reversal reason")
    detail_read_item(state, check_number: nil, **ZERO_ITEM)
    earning_only = detail_read_item(state, check_number: nil, **ZERO_ITEM)
    earning_only.payroll_item_earnings.create!(category: "regular", label: "Synthetic", amount: 10)
    deduction_only = detail_read_item(state, check_number: nil, **ZERO_ITEM)
    deduction_only.payroll_item_deductions.create!(deduction_type: DeductionType.create!(company: company, name: "Synthetic #{state[:sequence]}", category: "post_tax"),
      category: "post_tax", label: "Synthetic", amount: 10)

    # Retained empty row: never displayed or counted.
    empty = detail_read_item(state, check_number: nil, **ZERO_ITEM)
    PayrollItemLegacyDisposition.create!(payroll_item: empty, company: company, created_by: actor,
      reason: PayrollItemLegacyDisposition::REASON, evidence_digest: "d" * 64)
  end
end

RSpec.configure { |config| config.include PayPeriodDetailReadFixture }
