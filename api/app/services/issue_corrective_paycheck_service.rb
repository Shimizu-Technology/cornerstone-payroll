# frozen_string_literal: true

require "openssl"

# Issues a corrective paycheck for a single employee against an
# already-committed pay period — without voiding the original.
#
# How it works
# ============
#
# 1. We *recompute* what the original payroll item should have been with
#    the corrected inputs. The recompute uses the original period's pay
#    date / tax year and the YTD context that existed *just before* the
#    original was committed, so the tax math matches what would have been
#    withheld had the corrected inputs been entered originally.
#
# 2. We compute deltas: corrected_value - already_recorded_value for gross,
#    FIT, SS, Medicare, employer SS, employer Medicare, retirement,
#    additional withholding, deductions, and net pay.
#
# 3. We create a new pay_period with `cycle: 'supplemental'`,
#    `corrects_pay_period_id: original.id`, the same start/end dates
#    as the original, and a pay_date the operator picks (typically
#    "today" or the next regular pay date).
#
# 4. We add a single PayrollItem to the supplemental period that
#    *stores those deltas verbatim*, plus the linkage and reason.
#
# 5. We run the supplemental through the standard commit pipeline
#    (status: committed, YTD update, check number assignment, FIT
#    auto-deposit if enabled, tax sync enqueue).
#
# Why deltas (not absolute values) on the supplemental
# ----------------------------------------------------
#
# Every aggregate in the system that matters (EmployeeYtdTotal,
# CompanyYtdTotal, W-2 boxes, tax sync line items, reports) sums
# `payroll_items.gross_pay` etc. across `reportable_committed`
# pay_periods. A delta-valued supplemental therefore *just works*:
# `original.gross + active supplementals.gross = corrected.gross`.
# The check the operator hands the employee is the supplemental's
# `net_pay` (the net delta), which is exactly what we owe them.
#
# Limits / future work
# --------------------
# - Only positive corrections (delta net_pay > 0) generate a check.
#   Negative corrections (overpayment / clawback) are stored but the
#   operator is responsible for arranging recovery (e.g. a deduction
#   in the next regular period).
# - Contractor corrections aren't supported by this service; their
#   tax surface is zero and the existing payroll edit flow on a
#   draft period is sufficient.
# - Loan payments tied to deductions aren't re-applied for corrective
#   items: the original period's loan transactions stand. A corrective
#   that changes a loan deduction would need a separate flow.
class IssueCorrectivePaycheckService
  class CorrectionError < StandardError; end
  class InvalidStateError       < CorrectionError; end
  class OriginalNotFoundError   < CorrectionError; end
  class UnsupportedEmployeeError < CorrectionError; end
  class MissingHistoricalContextError < CorrectionError; end
  class StalePreviewError < CorrectionError; end

  # Fields the operator can override when issuing a correction. Anything
  # not provided falls back to the original item's value.
  CORRECTABLE_INPUT_FIELDS = %i[
    pay_rate
    salary_override
    hours_worked
    overtime_hours
    holiday_hours
    pto_hours
    bonus
    reported_tips
    tips_paid_out
    tip_pool
    additional_withholding
    additional_withholding_override
    withholding_tax_adjustment
    custom_earnings
    custom_deductions
    custom_columns_data
    non_taxable_pay
    service_charge_wages
    qualified_overtime_compensation
  ].freeze
  NUMERIC_INPUT_FIELDS = (CORRECTABLE_INPUT_FIELDS - %i[tip_pool custom_earnings custom_deductions custom_columns_data]).freeze
  SINGLE_RATE_HOUR_FIELDS = { "regular_hours" => :hours_worked, "overtime_hours" => :overtime_hours,
    "holiday_hours" => :holiday_hours, "pto_hours" => :pto_hours }.freeze

  # Fields whose deltas we transcribe onto the supplemental row. These
  # are the calculator's outputs; storing the deltas here is what makes
  # the YTD/W-2/report aggregates land on the corrected totals.
  DELTA_OUTPUT_FIELDS = %i[
    gross_pay
    withholding_tax
    social_security_tax
    medicare_tax
    employer_social_security_tax
    employer_medicare_tax
    additional_withholding
    retirement_payment
    roth_retirement_payment
    employer_retirement_match
    employer_roth_retirement_match
    total_additions
    total_deductions
    net_pay
  ].freeze

  REPORTING_DELTA_FIELDS = %i[
    fit_taxable_wages
    social_security_taxable_wages
    social_security_taxable_tips
    medicare_taxable_wages
    additional_medicare_taxable_wages
    additional_medicare_tax
    cash_tips_reported
    service_charge_wages
    qualified_overtime_compensation
  ].freeze

  # @param original_pay_period [PayPeriod]  must be committed, regular, non-voided
  # @param employee            [Employee]   must have an item in the original period
  # @param corrected_inputs    [Hash]       keys from CORRECTABLE_INPUT_FIELDS
  # @param pay_date            [Date]       when the corrective check will be issued
  # @param reason              [String]     mandatory explanation
  # @param actor               [User, nil]  user initiating the correction
  # @param notes               [String, nil] optional supplemental period notes
  def self.preview(original_pay_period:, employee:, corrected_inputs:)
    new(
      original_pay_period: original_pay_period,
      employee:            employee,
      corrected_inputs:    corrected_inputs
    ).preview
  end

  def self.issue!(original_pay_period:, employee:, corrected_inputs:,
                  pay_date:, reason:, actor: nil, notes: nil, expected_review_digest: nil)
    new(
      original_pay_period: original_pay_period,
      employee:            employee,
      corrected_inputs:    corrected_inputs,
      pay_date:            pay_date,
      reason:              reason,
      actor:               actor,
      notes:               notes,
      expected_review_digest: expected_review_digest
    ).issue!
  end

  def initialize(original_pay_period:, employee:, corrected_inputs:,
                 pay_date: nil, reason: nil, actor: nil, notes: nil, expected_review_digest: nil)
    @original_pay_period = original_pay_period
    @employee            = employee
    @corrected_inputs    = (corrected_inputs || {}).symbolize_keys
                                                  .slice(*CORRECTABLE_INPUT_FIELDS)
    @pay_date            = pay_date
    @reason              = reason
    @actor               = actor
    @notes               = notes
    @expected_review_digest = expected_review_digest
  end

  # Returns the original snapshot, the recomputed corrected snapshot, and
  # the deltas — without persisting anything. Used to drive the modal
  # preview before the operator commits.
  def preview
    validate_for_preview!
    {
      original:  snapshot(original_item),
      recorded: recorded_snapshot,
      corrected: snapshot(corrected_item),
      deltas:    delta_hash,
      meta: {
        original_pay_period_id: @original_pay_period.id,
        original_payroll_item_id: original_item.id,
        employee_id: @employee.id,
        employee_name: @employee.full_name,
        active_corrective_count: active_correctives.length,
        review_digest: review_digest,
        will_generate_check: net_delta.positive?,
        is_zero_change: zero_change?
      }
    }
  end

  def issue!
    validate_for_issue!
    PayPeriod.transaction do
      # Lock the original to prevent a concurrent void/correction on top
      # of us. We also re-read the latest state under lock.
      locked_original = PayPeriod.lock("FOR UPDATE").find(@original_pay_period.id)

      # Re-read the payroll item under a row-level lock so
      # `assert_correctable!` (and the corrected-item rebuild below) see the
      # latest voided?/check state, not the snapshot memoized during
      # `validate_for_issue!`. Without this, a concurrent void of the
      # original payroll item that commits in the window between
      # `validate_for_issue!` and this `FOR UPDATE` acquisition would slip
      # past the `original_item.voided?` guard — and a corrective delta
      # would then be applied against a YTD base the void has already
      # removed, corrupting the employee's year-end totals.
      refreshed = locked_original.payroll_items
                                 .lock("FOR UPDATE")
                                 .find_by(employee_id: @employee.id)
      if refreshed.nil?
        raise InvalidStateError,
              "Original payroll item no longer exists for this employee on the locked period"
      end
      @original_item = refreshed
      @original_pay_period = locked_original
      original_item.payroll_item_earnings.order(:id).lock("FOR UPDATE").load
      # A supplemental void takes its period lock before reversing YTD. Lock
      # those periods before reading the effective ledger or acquiring YTD.
      prior_ids = original_item.correction_payroll_items.distinct.pluck(:pay_period_id)
      PayPeriod.where(id: prior_ids).order(:id).lock("FOR UPDATE").load
      original_item.correction_payroll_items.order(:id).lock("FOR UPDATE").load
      # Force corrected_item to be rebuilt against the freshly-locked
      # original (its inputs are derived from `original_item.*`).
      @corrected_item = nil
      @recalculated_original_item = nil
      @active_correctives = nil
      @effective_inputs = nil

      assert_correctable!(locked_original)
      validate_for_issue!
      validate_review_digest!
      raise InvalidStateError, "The corrected target is already recorded; inputs do not change the remaining financial balance" if zero_change?

      supplemental = create_supplemental_period!(locked_original)
      corrective_item = create_corrective_item!(
        supplemental: supplemental,
        original_item: original_item
      )

      commit_supplemental!(supplemental)

      # Reload with associations so callers (and the API payload) see the
      # final committed state including check number assignment etc.
      supplemental.reload
      corrective_item.reload

      [ supplemental, corrective_item ]
    end
  end

  private

  # ---------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------
  def validate_for_preview!
    raise OriginalNotFoundError, "Original payroll item not found for employee in this pay period" if original_item.nil?
    validate_named_loan_replay!

    if original_item.employment_type == "contractor"
      raise UnsupportedEmployeeError,
            "Contractor payroll items don't have a tax surface to correct; edit the contractor item directly"
    end
    columns = @corrected_inputs[:custom_columns_data]
    categorized_target = columns.is_a?(Hash) && (columns["wage_rate_hours"].present? || columns[:wage_rate_hours].present?)
    if categorized_target
      raise UnsupportedEmployeeError, "Categorized or multi-rate payroll corrections require a category-level review; this corrective paycheck cannot safely recompute them"
    end
    verified_single_rate_row if original_item.wage_rate_hours.present?

    unless PayrollCalculationContext.valid_for_correction?(original_item.calculation_context_snapshot)
      raise MissingHistoricalContextError,
            "This payroll item predates immutable calculation snapshots and cannot be safely recomputed automatically"
    end
  end

  def validate_for_issue!
    validate_for_preview!
    raise ArgumentError, "reason is required" if @reason.blank?
    raise ArgumentError, "pay_date is required" if @pay_date.blank?

    # Temporal guard — the supplemental's `pay_date` must NOT predate the
    # original period's `pay_date`. `ytd_sum_excluding_original` (used to
    # build the pre-period YTD context for the corrected recompute) only
    # excludes items strictly *after* the original by `pay_date`. And
    # `reportable_committed` deliberately includes correction supplementals
    # (they're how YTD-aggregating reports stay correct).
    #
    # If a first correction is committed with a backdated `pay_date`
    # (older than the original) and then a second correction is issued
    # for the same original later, the first correction's delta would
    # land inside `ytd_sum_excluding_original`'s window — inflating the
    # second correction's pre-period YTD basis and corrupting its SS/FIT
    # math. The model-level `pay_date_after_end_date` validation only
    # enforces `pay_date >= end_date`, which (because there's typically
    # a gap between `end_date` and `pay_date`) leaves a window between
    # original's `end_date` and original's `pay_date` where this bug
    # is reachable through the API.
    parsed_pay_date = parsed_pay_date_for_validation
    if parsed_pay_date && parsed_pay_date < @original_pay_period.pay_date
      raise ArgumentError,
            "pay_date must be on or after the original period's pay_date " \
            "(#{@original_pay_period.pay_date})"
    end

    assert_correctable!(@original_pay_period)
  end

  # Coerces `@pay_date` (which may arrive as a Date, Time, or ISO string
  # from controllers) to a Date for the temporal-guard comparison.
  # Returns nil if it can't be parsed; the presence check above already
  # raises on a blank value, and the Postgres column-type cast catches
  # truly-malformed strings later in the flow — so we don't need to
  # ourselves raise here.
  def parsed_pay_date_for_validation
    return @pay_date if @pay_date.is_a?(Date)
    return @pay_date.to_date if @pay_date.respond_to?(:to_date) && !@pay_date.is_a?(String)
    Date.parse(@pay_date.to_s) rescue nil
  end

  def assert_correctable!(period)
    validate_named_loan_replay!
    unless period.can_issue_corrective_paycheck?
      raise InvalidStateError,
            "Pay period must be a regular committed (non-voided) period to issue a corrective paycheck"
    end
    if original_item.voided?
      raise InvalidStateError,
            "Cannot issue a corrective paycheck for an item whose original check is voided"
    end
  end

  def validate_named_loan_replay!
    return if original_item.named_loan_payments.blank?

    raise InvalidStateError,
          "This paycheck has a named loan override that cannot be safely replayed for a supplemental correction. Use unpaid payroll reopening if all payments are unissued and unpaid; otherwise arrange a reviewed paid-payroll and loan-ledger correction"
  end

  # ---------------------------------------------------------------------
  # Item lookup
  # ---------------------------------------------------------------------
  def original_item
    @original_item ||= @original_pay_period.payroll_items.find_by(employee_id: @employee.id)
  end

  # ---------------------------------------------------------------------
  # Recomputation: build a temporary "what it should have been" item and
  # run the calculator on it using the YTD context as it existed when the
  # original was processed.
  # ---------------------------------------------------------------------
  def corrected_item
    @corrected_item ||= build_and_calculate_item(effective_inputs.merge(@corrected_inputs))
  end

  def recalculated_original_item
    @recalculated_original_item ||= build_and_calculate_item(original_inputs)
  end

  def original_inputs
    CORRECTABLE_INPUT_FIELDS.index_with { |field| original_item.public_send(field) }.deep_dup
  end

  def verified_single_rate_row
    rows = original_item.wage_rate_hours
    raw_rows = original_item.custom_columns_data["wage_rate_hours"] || original_item.custom_columns_data[:wage_rate_hours]
    error = "The categorized or multi-rate historical snapshot is ambiguous or incomplete; review the native rate and earning evidence before correcting this payroll"
    unless original_item.employment_type == "hourly" && rows.one? && raw_rows.is_a?(Array) && raw_rows.one? && raw_rows.first.is_a?(Hash)
      raise UnsupportedEmployeeError, error
    end
    raw = raw_rows.first.stringify_keys
    row = rows.first
    required = %w[employee_wage_rate_id label rate active] + SINGLE_RATE_HOUR_FIELDS.keys
    valid = required.all? { |key| raw.key?(key) } && raw["label"].is_a?(String) && raw["label"].strip.present? && raw["active"] == true &&
      row["employee_wage_rate_id"].to_s.match?(/\A[1-9]\d*\z/) &&
      EmployeeWageRate.exists?(id: row["employee_wage_rate_id"], employee_id: original_item.employee_id)
    rate = BigDecimal(raw.fetch("rate").to_s)
    valid &&= rate.finite? && rate.positive? && rate == original_item.pay_rate.to_d
    valid &&= SINGLE_RATE_HOUR_FIELDS.all? do |key, field|
      hours = BigDecimal(raw.fetch(key).to_s)
      hours.finite? && !hours.negative? && hours == original_item.public_send(field).to_d
    end
    earnings = original_item.payroll_item_earnings.select { |earning| earning.category.in?(%w[regular overtime holiday pto]) }
    valid &&= earnings.any? && SINGLE_RATE_HOUR_FIELDS.all? do |key, field|
      category = key.delete_suffix("_hours")
      expected_hours = original_item.public_send(field).to_d
      matches = earnings.select { |earning| earning.category == category }
      next matches.empty? if expected_hours.zero?

      expected_rate = rate * (category == "overtime" ? 1.5.to_d : 1.to_d)
      label = category == "regular" ? row["label"] : "#{row['label']} #{category == 'pto' ? 'PTO' : category == 'overtime' ? 'OT' : 'Holiday'}"
      matches.one? && matches.first.persisted? && matches.first.label == label && matches.first.hours.to_d == expected_hours &&
        matches.first.rate.to_d == expected_rate && matches.first.amount.to_d == (expected_hours * expected_rate).round(2)
    end
    raise UnsupportedEmployeeError, error unless valid

    row
  rescue ArgumentError, TypeError, KeyError
    raise UnsupportedEmployeeError, "The historical rate snapshot is invalid; review the native earning evidence before correcting this payroll"
  end

  def single_rate_columns(columns, inputs, recorded: false)
    row = verified_single_rate_row
    if inputs.fetch(:pay_rate).to_d != row.fetch("rate").to_d
      raise UnsupportedEmployeeError, "A categorized rate change needs a category-level review; keep the verified historical rate for this hourly correction"
    end
    SINGLE_RATE_HOUR_FIELDS.each do |key, field|
      hours = inputs.fetch(field).to_d
      raise UnsupportedEmployeeError, "The recorded hours must be finite" unless hours.finite?
      raise UnsupportedEmployeeError, "The corrected absolute hours must be nonnegative" if !recorded && hours.negative?
      row[key] = hours.to_f
    end
    (columns || {}).deep_dup.merge("wage_rate_hours" => [ row ])
  end

  def active_correctives
    @active_correctives ||= original_item.correction_payroll_items.not_voided
      .joins(:pay_period).merge(PayPeriod.reportable_committed).order(:id).to_a.tap do |items|
        items.each do |item|
          unless item.company_id == original_item.company_id && item.employee_id == original_item.employee_id &&
              item.pay_period.company_id == original_item.company_id && item.pay_period.supplemental? &&
              item.pay_period.corrects_pay_period_id == original_item.pay_period_id
            raise MissingHistoricalContextError, "A prior correction has inconsistent payroll ownership; review its history before issuing another correction"
          end
        end
      end
  end

  def effective_inputs
    @effective_inputs ||= active_correctives.each_with_object(original_inputs) do |item, inputs|
      context = item.calculation_context_snapshot["corrective_paycheck"]
      unless context.is_a?(Hash) && context["version"] == 1 && context["input_adjustments"].is_a?(Hash)
        raise MissingHistoricalContextError, "A prior correction is missing its verified input history; review the earlier corrective payroll before creating another correction"
      end
      context.fetch("input_adjustments").each do |key, operation|
        field = key.to_sym
        unless CORRECTABLE_INPUT_FIELDS.include?(field) && operation.is_a?(Hash)
          raise MissingHistoricalContextError, "A prior correction has invalid input history; review the earlier corrective payroll"
        end
        inputs[field] = case operation["mode"]
        when "delta"
          unless NUMERIC_INPUT_FIELDS.include?(field) && operation["value"].is_a?(String)
            raise MissingHistoricalContextError, "A prior correction has invalid input history; review the earlier corrective payroll"
          end
          raise MissingHistoricalContextError, "A prior correction's input baseline is no longer available; review its voided correction history" if inputs[field].nil?
          inputs[field].to_d + BigDecimal(operation.fetch("value"))
        when "set"
          operation.fetch("value").deep_dup
        else
          raise MissingHistoricalContextError, "A prior correction has invalid input history; review the earlier corrective payroll"
        end
        if NUMERIC_INPUT_FIELDS.include?(field) && !inputs[field].nil?
          inputs[field] = BigDecimal(inputs[field].to_s)
          raise ArgumentError, "non-finite input" unless inputs[field].finite?
        end
      end
    end.tap do |inputs|
      if original_item.wage_rate_hours.present?
        # A void can leave the remaining signed deltas below zero. This is
        # recorded accounting history, not the absolute target to calculate.
        inputs[:custom_columns_data] = single_rate_columns(inputs[:custom_columns_data], inputs, recorded: true)
      end
    end
  rescue ArgumentError, TypeError, KeyError
    raise MissingHistoricalContextError, "A prior correction has invalid input history; review the earlier corrective payroll"
  end

  def input_adjustments
    CORRECTABLE_INPUT_FIELDS.each_with_object({}) do |field, adjustments|
      before = effective_inputs[field]
      after = corrected_item.public_send(field)
      next if before == after

      adjustments[field.to_s] = if before.is_a?(Numeric) && after.is_a?(Numeric)
        { "mode" => "delta", "value" => (after.to_d - before.to_d).to_s("F") }
      else
        { "mode" => "set", "value" => after.as_json }
      end
    end
  end

  def recorded_value(field)
    original_value = REPORTING_DELTA_FIELDS.include?(field) ? original_reporting_value(field) : original_item.public_send(field).to_d
    original_value + active_correctives.sum { |item| item.public_send(field).to_d }
  end

  def recorded_snapshot
    snapshot(original_item).merge(
      (DELTA_OUTPUT_FIELDS + REPORTING_DELTA_FIELDS).index_with { |field| recorded_value(field).round(2).to_f },
      effective_inputs.slice(:hours_worked, :overtime_hours, :holiday_hours, :pto_hours, :bonus, :reported_tips, :tips_paid_out, :pay_rate)
        .transform_values { |value| value.to_f },
      effective_inputs.slice(:custom_earnings, :custom_deductions, :custom_columns_data)
    )
  end

  def review_digest
    item_fields = CORRECTABLE_INPUT_FIELDS.map(&:to_s) + DELTA_OUTPUT_FIELDS.map(&:to_s) + REPORTING_DELTA_FIELDS.map(&:to_s) +
      %w[id company_id employee_id pay_period_id updated_at voided voided_at calculation_context_snapshot tax_rule_snapshot retirement_rule_snapshot]
    period_fields = %w[id company_id pay_date status correction_status committed_at voided_at updated_at]
    state = {
      version: 1,
      original_period: @original_pay_period.attributes.slice(*period_fields),
      original_item: original_item.attributes.slice(*item_fields),
      original_earnings: original_item.payroll_item_earnings.order(:id).map { |earning| earning.attributes.slice("id", "category", "label", "rate", "hours", "amount", "updated_at") },
      active_correctives: active_correctives.map do |item|
        { item: item.attributes.slice(*item_fields), period: item.pay_period.attributes.slice(*period_fields) }
      end,
      corrected_snapshot: snapshot(corrected_item),
      intended_inputs: CORRECTABLE_INPUT_FIELDS.index_with { |field| corrected_item.public_send(field) }
    }
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, JSON.generate(canonical_review_state(state.as_json)))
  end

  def canonical_review_state(value)
    case value
    when Hash
      value.sort.to_h.transform_values { |entry| canonical_review_state(entry) }
    when Array
      value.map { |entry| canonical_review_state(entry) }
    else
      value
    end
  end

  def validate_review_digest!
    return if @expected_review_digest.nil?

    valid = @expected_review_digest.is_a?(String) && @expected_review_digest.match?(/\A[0-9a-f]{64}\z/) &&
      ActiveSupport::SecurityUtils.secure_compare(@expected_review_digest, review_digest)
    return if valid

    raise StalePreviewError, "The correction preview changed. Refresh and review the current remaining balance before issuing this correction"
  end

  def build_and_calculate_item(overrides)
    input_value = ->(key, fallback) { overrides.key?(key) ? overrides[key] : fallback }
    temp = PayrollItem.new(
      employee_id:              @employee.id,
      company_id:               @original_pay_period.company_id,
      pay_period_id:            @original_pay_period.id, # for pay_date / tax year context
      employment_type:          original_item.employment_type,

      # Inputs: original values overlaid with operator-supplied corrections.
      pay_rate:                 input_value.call(:pay_rate, original_item.pay_rate),
      salary_override:          input_value.call(:salary_override, original_item.salary_override),
      scheduled_hours:          original_item.scheduled_hours,
      hours_worked:             input_value.call(:hours_worked, original_item.hours_worked),
      overtime_hours:           input_value.call(:overtime_hours, original_item.overtime_hours),
      holiday_hours:            input_value.call(:holiday_hours, original_item.holiday_hours),
      pto_hours:                input_value.call(:pto_hours, original_item.pto_hours),
      bonus:                    input_value.call(:bonus, original_item.bonus),
      reported_tips:            input_value.call(:reported_tips, original_item.reported_tips),
      tips_paid_out:            input_value.call(:tips_paid_out, original_item.tips_paid_out),
      tip_pool:                 input_value.call(:tip_pool, original_item.tip_pool),
      non_taxable_pay:          input_value.call(:non_taxable_pay, original_item.non_taxable_pay),
      service_charge_wages:     input_value.call(:service_charge_wages, original_item.service_charge_wages),
      qualified_overtime_compensation: input_value.call(
        :qualified_overtime_compensation,
        original_item.qualified_overtime_compensation
      ),
      additional_withholding:   input_value.call(:additional_withholding, original_item.additional_withholding),
      additional_withholding_override: input_value.call(:additional_withholding_override, original_item.additional_withholding_override),
      withholding_tax_adjustment: input_value.call(:withholding_tax_adjustment, original_item.withholding_tax_adjustment),
      withholding_tax_override: original_item.withholding_tax_override, # not currently overridable
      custom_earnings:          input_value.call(:custom_earnings, original_item.custom_earnings),
      custom_deductions:        input_value.call(:custom_deductions, original_item.custom_deductions),
      custom_columns_data:      input_value.call(:custom_columns_data, original_item.custom_columns_data),
      loan_deduction:           original_item.loan_deduction,
      import_source:            original_item.import_source,
      timekeeping_source:       "correction_reference",
      timekeeping_context_snapshot: original_item.timekeeping_context_snapshot
    )
    temp.pay_period = @original_pay_period
    SINGLE_RATE_HOUR_FIELDS.each_value do |field|
      hours = temp.public_send(field).to_d
      raise UnsupportedEmployeeError, "The corrected absolute hours must be nonnegative" if hours.negative? || !hours.finite?
    end
    if original_item.wage_rate_hours.present?
      target_inputs = SINGLE_RATE_HOUR_FIELDS.values.index_with { |field| temp.public_send(field) }.merge(pay_rate: temp.pay_rate)
      temp.custom_columns_data = single_rate_columns(temp.custom_columns_data, target_inputs)
    end
    temp.payroll_adjustments = original_item.payroll_adjustments.deep_dup
    temp.tax_rule_snapshot = original_item.tax_rule_snapshot.deep_dup
    temp.retirement_rule_snapshot = original_item.retirement_rule_snapshot.deep_dup
    clone_original_payroll_field_entries!(temp)

    # Stub YTD context to "as it was when the original was first calculated":
    # i.e. exclude the original item itself from the YTD aggregates. This
    # makes the recomputed taxes match what would have been withheld had
    # the corrected inputs been on the original run.
    with_ytd_excluding_original do
      # A correction recomputes the historical item, so its calculator must
      # follow the original payroll snapshot rather than the employee's current
      # classification. This also keeps the supplemental row and its tax
      # treatment on the same side of W-2/contractor reporting filters.
      PayrollCalculator.for(
        @employee,
        temp,
        employment_type: temp.employment_type,
        calculation_context: original_item.calculation_context_snapshot
      ).calculate
    end

    temp
  end

  def clone_original_payroll_field_entries!(temp)
    original_item.payroll_item_field_entries.each do |entry|
      temp.payroll_item_field_entries.build(
        payroll_field_definition_id: entry.payroll_field_definition_id,
        label: entry.label,
        kind: entry.kind,
        tax_treatment: entry.tax_treatment,
        category: entry.category,
        amount: entry.amount,
        employee_paid: entry.employee_paid,
        employer_paid: entry.employer_paid,
        reporting_group: entry.reporting_group,
        active: entry.active,
        source: entry.source,
        notes: entry.notes,
        metadata: entry.metadata.deep_dup
      )
    end
  end

  # Override the employee's cached pre-period YTD totals with figures that
  # exclude the original payroll item, so PayrollCalculator uses the
  # corrected baseline while recomputing the supplemental delta.
  def with_ytd_excluding_original
    previous_snapshot = @employee.cached_ytd_snapshot

    @employee.cache_ytd_values!(
      year: @original_pay_period.pay_date.year,
      as_of_pay_date: @original_pay_period.pay_date,
      before_pay_period_id: @original_pay_period.id,
      totals: cached_ytd_totals_excluding_original
    )

    yield
  ensure
    @employee.restore_cached_ytd_snapshot!(previous_snapshot)
  end

  # YTD across all reportable_committed periods *prior to* the original
  # period's pay_date for the same year, plus same-pay-date periods with
  # an earlier id (deterministic ordering for same-day batches).
  # Excludes the original period itself.
  def ytd_gross_excluding_original
    ytd_sum_excluding_original(:gross_pay)
  end

  def ytd_ss_excluding_original
    ytd_sum_excluding_original(:social_security_tax)
  end

  def cached_ytd_totals_excluding_original
    pay_date = @original_pay_period.pay_date
    year = pay_date.year
    scope = @employee.payroll_items
      .joins(:pay_period)
      .not_voided
      .where(pay_periods: { id: PayPeriod.reportable_committed
                                          .where(company_id: @original_pay_period.company_id,
                                                 pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                                          .select(:id) })
      .where("(pay_periods.pay_date < ?) OR (pay_periods.pay_date = ? AND pay_periods.id < ?)",
             pay_date, pay_date, @original_pay_period.id)

    @employee.ytd_totals_for_scope(scope, tax_year: year)
  end

  def ytd_sum_excluding_original(column)
    pay_date = @original_pay_period.pay_date
    year = pay_date.year
    @employee.payroll_items
      .joins(:pay_period)
      .not_voided
      .where(pay_periods: { id: PayPeriod.reportable_committed
                                          .where(company_id: @original_pay_period.company_id,
                                                 pay_date: Date.new(year, 1, 1)..Date.new(year, 12, 31))
                                          .select(:id) })
      .where("(pay_periods.pay_date < ?) OR (pay_periods.pay_date = ? AND pay_periods.id < ?)",
             pay_date, pay_date, @original_pay_period.id)
      .sum(column)
  end

  # ---------------------------------------------------------------------
  # Inputs / deltas
  # ---------------------------------------------------------------------
  def corrected_tip_pool
    source = @corrected_inputs.key?(:tip_pool) ? @corrected_inputs[:tip_pool] : corrected_item.tip_pool
    source.presence
  end

  def snapshot(item)
    (DELTA_OUTPUT_FIELDS + REPORTING_DELTA_FIELDS).each_with_object({}) do |field, h|
      h[field] = item.public_send(field).to_f.round(4)
    end.merge(
      hours_worked:   item.hours_worked.to_f,
      overtime_hours: item.overtime_hours.to_f,
      holiday_hours:  item.holiday_hours.to_f,
      pto_hours:      item.pto_hours.to_f,
      bonus:          item.bonus.to_f,
      reported_tips:  item.reported_tips.to_f,
      tips_paid_out:  item.tips_paid_out.to_f,
      pay_rate:       item.pay_rate.to_f,
      custom_earnings: Array(item.custom_earnings),
      custom_deductions: Array(item.custom_deductions),
      custom_columns_data: item.custom_columns_data || {}
    )
  end

  def delta_hash
    financial_deltas = DELTA_OUTPUT_FIELDS.each_with_object({}) do |field, h|
      h[field] = (corrected_item.public_send(field).to_d - recorded_value(field)).round(2).to_f
    end
    reporting_deltas = REPORTING_DELTA_FIELDS.each_with_object({}) do |field, deltas|
      deltas[field] = (corrected_item.public_send(field).to_d - recorded_value(field)).round(2)
    end

    financial_deltas.merge(reporting_deltas).merge(
      hours_worked_delta:   (corrected_item.hours_worked.to_d - effective_inputs[:hours_worked].to_d).round(2),
      overtime_hours_delta: (corrected_item.overtime_hours.to_d - effective_inputs[:overtime_hours].to_d).round(2),
      holiday_hours_delta:  (corrected_item.holiday_hours.to_d - effective_inputs[:holiday_hours].to_d).round(2),
      pto_hours_delta:      (corrected_item.pto_hours.to_d - effective_inputs[:pto_hours].to_d).round(2),
      reported_tips_delta:  (corrected_item.reported_tips.to_d - effective_inputs[:reported_tips].to_d).round(2),
      tips_paid_out_delta:  (corrected_item.tips_paid_out.to_d - effective_inputs[:tips_paid_out].to_d).round(2)
    )
  end

  def original_reporting_value(field)
    stored_value = original_item.public_send(field)
    return stored_value.to_d unless stored_value.nil?

    recalculated_original_item.public_send(field).to_d
  end

  def net_delta
    (corrected_item.net_pay.to_d - recorded_value(:net_pay)).round(2)
  end

  # No meaningful change → nothing to do.
  def zero_change?
    delta_hash.slice(*DELTA_OUTPUT_FIELDS).values.all? { |v| v.abs < 0.005 }
  end

  # ---------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------
  def create_supplemental_period!(original)
    PayPeriod.create!(
      company_id:              original.company_id,
      start_date:              original.start_date,
      end_date:                original.end_date,
      pay_date:                @pay_date,
      status:                  "draft",
      cycle:                   "supplemental",
      run_purpose:             "correction",
      includes_base_salary:    false,
      includes_recurring_items: false,
      run_purpose_source:      "system_correction",
      corrects_pay_period_id:  original.id,
      notes:                   build_notes(original)
    )
  end

  def build_notes(original)
    base = "Corrective paycheck for #{@employee.full_name} against pay period " \
           "#{original.start_date} – #{original.end_date}: #{@reason}"
    @notes.present? ? "#{base}\n#{@notes}" : base
  end

  def create_corrective_item!(supplemental:, original_item:)
    deltas = delta_hash

    item = supplemental.payroll_items.build(
      employee_id:                       @employee.id,
      company_id:                        supplemental.company_id,
      employment_type:                   original_item.employment_type,
      payment_delivery_method:          @employee.payment_delivery_method.presence || "paper_check",
      correction_for_payroll_item_id:    original_item.id,
      correction_reason:                 @reason,

      # Hours/inputs are stored as deltas (so summing across the
      # original + supplemental yields the corrected totals).
      pay_rate:        original_item.pay_rate, # rate isn't a delta — keep for reporting
      scheduled_hours: 0,
      hours_worked:    deltas[:hours_worked_delta],
      overtime_hours:  deltas[:overtime_hours_delta],
      holiday_hours:   deltas[:holiday_hours_delta],
      pto_hours:       deltas[:pto_hours_delta],
      timekeeping_source: "correction_reference",
      timekeeping_context_snapshot: original_item.timekeeping_context_snapshot,
      calculation_context_snapshot: corrected_item.calculation_context_snapshot.deep_dup.merge(
        "corrective_paycheck" => { "version" => 1, "input_adjustments" => input_adjustments }
      ),

      # Tip deltas are stored too because W-2GU / 941 / SWICA reporting derives
      # Social Security tips and YTD tip totals from these input columns, while
      # gross/tax/net deltas below make the corrective check amount right.
      reported_tips:                   deltas[:reported_tips_delta],
      tips_paid_out:                   deltas[:tips_paid_out_delta],
      tip_pool:                        corrected_tip_pool,

      # Financial deltas: assigned directly so the standard commit
      # pipeline (YTD update / check number assignment) treats them as
      # the supplemental's authoritative values without a recalculate.
      gross_pay:                       deltas[:gross_pay],
      withholding_tax:                 deltas[:withholding_tax],
      social_security_tax:             deltas[:social_security_tax],
      medicare_tax:                    deltas[:medicare_tax],
      employer_social_security_tax:    deltas[:employer_social_security_tax],
      employer_medicare_tax:           deltas[:employer_medicare_tax],
      additional_withholding:          deltas[:additional_withholding],
      retirement_payment:              deltas[:retirement_payment],
      roth_retirement_payment:         deltas[:roth_retirement_payment],
      employer_retirement_match:       deltas[:employer_retirement_match],
      employer_roth_retirement_match:  deltas[:employer_roth_retirement_match],
      total_additions:                 deltas[:total_additions],
      total_deductions:                deltas[:total_deductions],
      net_pay:                         deltas[:net_pay],
      fit_taxable_wages:               deltas[:fit_taxable_wages],
      social_security_taxable_wages:   deltas[:social_security_taxable_wages],
      social_security_taxable_tips:    deltas[:social_security_taxable_tips],
      medicare_taxable_wages:          deltas[:medicare_taxable_wages],
      additional_medicare_taxable_wages: deltas[:additional_medicare_taxable_wages],
      additional_medicare_tax:         deltas[:additional_medicare_tax],
      cash_tips_reported:              deltas[:cash_tips_reported],
      service_charge_wages:            deltas[:service_charge_wages],
      qualified_overtime_compensation: deltas[:qualified_overtime_compensation],
      annual_tax_config_id:            corrected_item.annual_tax_config_id,
      tax_rule_snapshot:               corrected_item.tax_rule_snapshot,
      retirement_rule_snapshot:        corrected_item.retirement_rule_snapshot,

      # No deductions on the corrective row — the original period already
      # captured the period's deductions; the corrective covers only the
      # missing wages + their associated taxes.
      loan_payment:                    0.0,
      insurance_payment:               0.0
    )
    item.save!
    item
  end

  # Mirrors PayPeriodsController#commit, scoped to the supplemental's
  # single item — without re-running the calculator (we already filled in
  # the delta values authoritatively).
  def commit_supplemental!(supplemental)
    supplemental.update!(status: "committed", committed_at: Time.current)

    # YTD and check number — same primitives the regular commit uses.
    supplemental.payroll_items.each do |item|
      employee_ytd = item.employee.ytd_totals_for(supplemental.pay_date.year)
      employee_ytd.add_payroll_item!(item)

      company_ytd = CompanyYtdTotal.find_or_create_by(company_id: item.company_id, year: supplemental.pay_date.year)
      company_ytd.add_payroll_item!(item)
    end

    PayrollLiabilityPostingService.post!(
      pay_period: supplemental,
      actor: @actor
    )

    # Only assign a check number if there's actually money to pay out.
    # Negative net (clawback) supplementals exist as accounting entries
    # but don't generate paper.
    items_needing_check = supplemental.payroll_items
      .where(check_number: nil)
      .select { |i| i.net_pay.to_f > 0 && i.payment_delivery_method == "paper_check" }
    supplemental.company.assign_check_numbers!(items_needing_check) if items_needing_check.any?

    # FIT auto-deposit: if there's a positive FIT delta and the company
    # has the auto-deposit setting on, generate the supplemental's own
    # FIT NonEmployeeCheck. Re-uses the existing controller method via
    # an inline implementation to avoid coupling. The unique-per-period
    # index on auto_generated_type guarantees no duplicates within the
    # supplemental period.
    create_supplemental_fit_check!(supplemental) if supplemental.company.auto_create_fit_check?

    # Tax sync — the supplemental gets its own idempotency key and is
    # pushed independently only when the external CST ingest integration is configured.
    if supplemental.prepare_tax_sync_if_configured!
      ActiveRecord.after_all_transactions_commit do
        PayrollTaxSyncJob.perform_later(supplemental.id)
      end
    end
  end

  def create_supplemental_fit_check!(supplemental)
    fit_total = supplemental.payroll_items
      .where(employment_type: %w[hourly salary])
      .not_voided
      .sum { |item| item.total_income_tax_withheld }

    return if fit_total.to_f <= 0 # no positive FIT delta → no deposit needed

    check = NonEmployeeCheck.create!(
      company_id:           supplemental.company_id,
      pay_period_id:        supplemental.id,
      created_by:           @actor,
      payable_to:           "Treasurer of Guam",
      amount:               fit_total,
      check_type:           "tax_deposit",
      auto_generated_type:  NonEmployeeCheck::AUTO_GENERATED_TYPES[:fit_deposit],
      payment_period_type:  "pay_period",
      payment_date:         supplemental.pay_date,
      memo:                 "FIT deposit for corrective paycheck (#{supplemental.start_date} – #{supplemental.end_date})",
      description:          "Federal Income Tax (FIT) — corrective deposit for #{@employee.full_name}"
    )
    PayrollLiabilityFitPaymentConnector.connect!(
      non_employee_check: check,
      pay_period: supplemental,
      actor: @actor
    )
  rescue PayrollLiabilityCheckAllocationService::Error => e
    raise CorrectionError, "FIT payment could not be connected to its payroll liabilities: #{e.message}"
  end
end
