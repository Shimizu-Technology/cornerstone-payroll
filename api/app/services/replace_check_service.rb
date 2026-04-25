# frozen_string_literal: true

# Replaces an employee's payroll check on a committed pay period when the
# original check is *not in the wild* — either it was never handed out, or
# the employee returned it uncashed.
#
# The service edits the payroll_item in place to the corrected values,
# fixes YTD by subtracting the original contribution and re-adding the
# corrected one, and (for already-printed checks) voids the old check
# number and assigns a new one. The result is a single clean replacement
# check at the corrected amount.
#
# Contrast with IssueCorrectivePaycheckService
# --------------------------------------------
# - IssueCorrectivePaycheckService is for the **already-cashed** case:
#   the original check stays untouched and a *second* supplemental check
#   is cut for just the difference. Two checks for the employee.
# - ReplaceCheckService is for the **uncashed** case: the original is
#   voided and replaced with a single corrected check. One check for
#   the employee.
#
# Modes
# -----
# - `:in_place` — used when the original check was committed but never
#   printed (`check_printed_at IS NULL`). The check number is reused;
#   no void event is logged because no physical paper went out.
# - `:void_and_reissue` — used when the original was printed (and is
#   now back in our possession). The old check number is voided in the
#   audit trail, a fresh check number is assigned, and the new one
#   becomes the canonical check for the period.
#
# Auditing
# --------
# Every replacement records a `check_event` with `event_type: "replaced"`
# whose `reason` field carries a structured human-readable summary
# (`"Replace (uncashed): hours 60→80, gross $900.00→$1200.00, net $...→$...
# (operator reason: …)"`). For the void+reissue path a paired `"voided"`
# event captures the old check number's invalidation. Together they form
# a complete audit trail without requiring a new JSONB snapshot column.
class ReplaceCheckService
  class ReplaceError < StandardError; end
  class InvalidStateError       < ReplaceError; end
  class UnsupportedEmployeeError < ReplaceError; end
  class InvalidInputError       < ReplaceError; end

  # Same set the corrective service accepts. Anything not provided falls
  # back to the existing payroll_item value.
  #
  # `wage_rate_hours` is the per-rate-bucket breakdown for multi-rate
  # employees (e.g., a pilot with separate Flight / Admin / Ground rates).
  # When present, the calculator overrides the aggregate `hours_worked`,
  # `overtime_hours`, etc. with sums computed from the per-bucket entries
  # — so editing just `hours_worked` for a multi-rate employee would be
  # silently ignored. This field lets the Replace flow correctly redistribute
  # hours across buckets (e.g., move 1 admin hour → 14.3 flight + 3.2 ground).
  # Setter on PayrollItem normalizes entries into custom_columns_data.
  REPLACEABLE_INPUT_FIELDS = %i[
    pay_rate
    hours_worked
    overtime_hours
    holiday_hours
    pto_hours
    bonus
    reported_tips
    additional_withholding
    withholding_tax_adjustment
    custom_earnings
    non_taxable_pay
    wage_rate_hours
  ].freeze

  # Fields we snapshot for the audit summary. Compact subset — the full
  # before/after is recoverable from check_events.created_at + the audit
  # log of the replaced check.
  AUDIT_SNAPSHOT_FIELDS = %i[
    hours_worked
    overtime_hours
    pay_rate
    bonus
    gross_pay
    withholding_tax
    social_security_tax
    medicare_tax
    net_pay
  ].freeze

  def self.preview(payroll_item:, corrected_inputs:)
    new(payroll_item: payroll_item, corrected_inputs: corrected_inputs).preview
  end

  def self.replace!(payroll_item:, corrected_inputs:, reason:, actor:, ip_address: nil)
    new(
      payroll_item:     payroll_item,
      corrected_inputs: corrected_inputs,
      reason:           reason,
      actor:            actor,
      ip_address:       ip_address
    ).replace!
  end

  def initialize(payroll_item:, corrected_inputs:, reason: nil, actor: nil, ip_address: nil)
    @payroll_item     = payroll_item
    @corrected_inputs = (corrected_inputs || {}).symbolize_keys
                                                .slice(*REPLACEABLE_INPUT_FIELDS)
    @reason           = reason
    @actor            = actor
    @ip_address       = ip_address
  end

  # Read-only delta computation for the modal — does not touch the DB.
  def preview
    validate_for_preview!
    {
      original:  snapshot(@payroll_item),
      corrected: snapshot(simulated_corrected_item),
      mode:      detect_mode,
      meta: {
        payroll_item_id: @payroll_item.id,
        employee_id:     @payroll_item.employee_id,
        employee_name:   @payroll_item.employee_full_name,
        will_assign_new_check_number: detect_mode == :void_and_reissue,
        original_check_number: @payroll_item.check_number,
        is_zero_change: zero_change?(simulated_corrected_item)
      }
    }
  end

  # Perform the replacement. Returns the reloaded payroll_item.
  def replace!
    validate_for_replace!

    PayrollItem.transaction do
      @payroll_item.lock!
      assert_replaceable!

      mode = detect_mode

      original_snapshot      = snapshot(@payroll_item)
      original_check_number  = @payroll_item.check_number

      # Step 1 — pull the original's contribution out of YTD before we mutate
      # the item. We re-add the corrected contribution at the end so the YTD
      # ends up reflecting the new (corrected) values atomically.
      employee_ytd = @payroll_item.employee.ytd_totals_for(year)
      company_ytd  = CompanyYtdTotal.find_or_create_by(
        company_id: @payroll_item.company_id,
        year:       year
      )
      employee_ytd.subtract_payroll_item!(@payroll_item)
      company_ytd.subtract_payroll_item!(@payroll_item)

      # Step 2 — mode-specific handling for the old check number.
      new_check_number = nil
      if mode == :void_and_reissue
        @payroll_item.check_events.create!(
          user:         @actor,
          event_type:   "voided",
          check_number: original_check_number,
          reason:       "Replaced (uncashed) — superseded by new check (#{@reason})",
          ip_address:   @ip_address
        )
        new_check_number = @payroll_item.pay_period.company.next_check_number!
      end

      # Step 3 — apply corrected inputs to the item and recompute everything.
      apply_corrected_inputs_to(@payroll_item)
      recompute_with_ytd_excluding_self(@payroll_item)

      # Step 4 — persist the replacement on the same row.
      update_attrs = {
        check_printed_at:  nil,
        check_print_count: 0
      }
      if mode == :void_and_reissue
        update_attrs[:check_number]            = new_check_number
        update_attrs[:replaced_check_number]   = original_check_number
      end
      @payroll_item.assign_attributes(update_attrs)
      @payroll_item.save!

      # Step 5 — re-add to YTD with the new (corrected) values.
      employee_ytd.add_payroll_item!(@payroll_item)
      company_ytd.add_payroll_item!(@payroll_item)

      # Step 6 — audit-log the replacement.
      after_snapshot = snapshot(@payroll_item)
      @payroll_item.check_events.create!(
        user:         @actor,
        event_type:   "replaced",
        check_number: @payroll_item.check_number || original_check_number,
        reason:       audit_summary(
          mode:               mode,
          before:             original_snapshot,
          after:              after_snapshot,
          original_check_number: original_check_number,
          new_check_number:      new_check_number,
          operator_reason:    @reason
        ),
        ip_address:   @ip_address
      )

      @payroll_item.reload
    end
  end

  private

  # ---------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------
  def validate_for_preview!
    # Nil-check must precede any predicate calls — otherwise a nil
    # `@payroll_item` would `NoMethodError` on `.contractor?` before this
    # guard fires. The controller's `before_action :set_payroll_item`
    # makes nil unreachable in practice, but the service may also be
    # called directly (specs, jobs, console), so order matters.
    raise InvalidStateError, "Original payroll item is missing" if @payroll_item.nil?
    raise UnsupportedEmployeeError, "Replace flow doesn't support contractor checks" if @payroll_item.contractor?
    if @payroll_item.correction_entry?
      raise InvalidStateError,
            "Cannot replace a corrective entry directly — replace the original payroll item instead"
    end
  end

  def validate_for_replace!
    validate_for_preview!
    raise InvalidInputError, "Reason is required (minimum 10 characters)" if @reason.to_s.strip.length < 10
    raise InvalidInputError, "Actor (user) is required" if @actor.nil?
    raise InvalidInputError,
          "Replace requires a positive corrected gross — to fully cancel the check use the standard void flow" \
      if simulated_corrected_item.gross_pay.to_f <= 0
    raise InvalidStateError, "No change in financial values — nothing to replace" if zero_change?(simulated_corrected_item)
  end

  def assert_replaceable!
    period = @payroll_item.pay_period
    unless period.committed?
      raise InvalidStateError, "Replace flow is only available for committed pay periods"
    end
    if period.respond_to?(:supplemental?) && period.supplemental?
      raise InvalidStateError,
            "Cannot replace a check on a supplemental period — supplementals are corrective entries themselves"
    end
    if @payroll_item.voided?
      raise InvalidStateError, "Cannot replace an already-voided check"
    end
    if @payroll_item.check_number.blank?
      raise InvalidStateError, "Payroll item has no check number — nothing to replace"
    end
  end

  # ---------------------------------------------------------------------
  # Mode + simulation
  # ---------------------------------------------------------------------
  def detect_mode
    @payroll_item.check_printed_at.present? ? :void_and_reissue : :in_place
  end

  # Build a duck-typed clone of the item with corrected inputs *and* run
  # the calculator on it (using YTD context that excludes the original).
  # Memoized — the modal calls this twice for snapshot vs delta.
  def simulated_corrected_item
    @simulated_corrected_item ||= begin
      temp = @payroll_item.dup
      temp.id          = @payroll_item.id    # keep ID so YTD-excludes-self matches
      temp.pay_period  = @payroll_item.pay_period
      temp.employee    = @payroll_item.employee
      apply_corrected_inputs_to(temp)
      recompute_with_ytd_excluding_self(temp)
      temp
    end
  end

  def apply_corrected_inputs_to(item)
    REPLACEABLE_INPUT_FIELDS.each do |field|
      next unless @corrected_inputs.key?(field)
      item.public_send("#{field}=", @corrected_inputs[field])
    end
  end

  # Override the employee's cached pre-period YTD totals with figures that
  # exclude this item, so PayrollCalculator uses the corrected baseline
  # instead of re-reading aggregates that still include the old row.
  def recompute_with_ytd_excluding_self(item)
    employee = item.employee
    previous_snapshot = employee.cached_ytd_snapshot

    employee.cache_ytd_values!(
      year: item.pay_period.pay_date.year,
      as_of_pay_date: item.pay_period.pay_date,
      before_pay_period_id: item.pay_period_id,
      totals: cached_ytd_totals_excluding_self
    )

    PayrollCalculator.for(employee, item).calculate
  ensure
    employee.restore_cached_ytd_snapshot!(previous_snapshot)
  end

  # YTD across all reportable_committed periods *prior to* this item's
  # pay_date in the same year (with same-pay-date deterministic ordering
  # by pay_period.id, mirroring IssueCorrectivePaycheckService). Excludes
  # the item itself.
  #
  # The pay_date cutoff is critical: PayrollCalculator uses this value
  # as the "pre-period YTD" baseline for SS-wage-base and FIT-bracket
  # calculations. Without the cutoff, items from *later* committed
  # periods in the same year leak in — which can falsely push the
  # employee past the SS wage base (zeroing SS on the replacement) or
  # bump them into a higher FIT bracket than was correct at the time
  # of the original period.
  def ytd_excluding_self(column)
    pay_date = @payroll_item.pay_period.pay_date
    pay_period_id = @payroll_item.pay_period_id
    @payroll_item.employee.payroll_items
      .joins(:pay_period)
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
                     .where(company_id: @payroll_item.company_id,
                            pay_date: Date.new(pay_date.year, 1, 1)..Date.new(pay_date.year, 12, 31))
                     .select(:id)
      })
      .where("(pay_periods.pay_date < ?) OR (pay_periods.pay_date = ? AND pay_periods.id < ?)",
             pay_date, pay_date, pay_period_id)
      .where.not(id: @payroll_item.id)
      .sum(column)
  end

  def cached_ytd_totals_excluding_self
    pay_date = @payroll_item.pay_period.pay_date
    pay_period_id = @payroll_item.pay_period_id
    scope = @payroll_item.employee.payroll_items
      .joins(:pay_period)
      .where(pay_periods: {
        id: PayPeriod.reportable_committed
                     .where(company_id: @payroll_item.company_id,
                            pay_date: Date.new(pay_date.year, 1, 1)..Date.new(pay_date.year, 12, 31))
                     .select(:id)
      })
      .where("(pay_periods.pay_date < ?) OR (pay_periods.pay_date = ? AND pay_periods.id < ?)",
             pay_date, pay_date, pay_period_id)
      .where.not(id: @payroll_item.id)

    @payroll_item.employee.ytd_totals_for_scope(scope)
  end

  # ---------------------------------------------------------------------
  # Snapshots / audit summary
  # ---------------------------------------------------------------------
  def snapshot(item)
    AUDIT_SNAPSHOT_FIELDS.each_with_object({}) do |field, h|
      h[field] = item.public_send(field).to_f.round(4)
    end
  end

  def zero_change?(corrected)
    AUDIT_SNAPSHOT_FIELDS.all? do |field|
      (corrected.public_send(field).to_f - @payroll_item.public_send(field).to_f).abs < 0.005
    end
  end

  def audit_summary(mode:, before:, after:, original_check_number:, new_check_number:, operator_reason:)
    parts = []
    parts << (mode == :void_and_reissue ? "Replace (uncashed, printed)" : "Replace (unprinted, in-place)")
    if mode == :void_and_reissue
      parts << "old check ##{original_check_number} voided → new check ##{new_check_number}"
    else
      parts << "check ##{original_check_number} (no #-change)"
    end
    parts << "hours #{before[:hours_worked]}→#{after[:hours_worked]}" \
      if (after[:hours_worked] - before[:hours_worked]).abs > 0.005
    parts << "gross $#{format('%.2f', before[:gross_pay])}→$#{format('%.2f', after[:gross_pay])}"
    parts << "FIT $#{format('%.2f', before[:withholding_tax])}→$#{format('%.2f', after[:withholding_tax])}"
    parts << "net $#{format('%.2f', before[:net_pay])}→$#{format('%.2f', after[:net_pay])}"
    parts << "(operator reason: #{operator_reason})"
    parts.join(" | ")
  end

  def year
    @payroll_item.pay_period.pay_date.year
  end
end
