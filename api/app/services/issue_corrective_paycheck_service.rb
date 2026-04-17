# frozen_string_literal: true

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
# 2. We compute deltas: corrected_value - original_value for gross,
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
# `original.gross + supplemental.gross_delta = corrected.gross`.
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

  # Fields the operator can override when issuing a correction. Anything
  # not provided falls back to the original item's value.
  CORRECTABLE_INPUT_FIELDS = %i[
    pay_rate
    hours_worked
    overtime_hours
    holiday_hours
    pto_hours
    bonus
    reported_tips
    tip_pool
    additional_withholding
    custom_earnings
    custom_columns_data
    non_taxable_pay
  ].freeze

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
                  pay_date:, reason:, actor: nil, notes: nil)
    new(
      original_pay_period: original_pay_period,
      employee:            employee,
      corrected_inputs:    corrected_inputs,
      pay_date:            pay_date,
      reason:              reason,
      actor:               actor,
      notes:               notes
    ).issue!
  end

  def initialize(original_pay_period:, employee:, corrected_inputs:,
                 pay_date: nil, reason: nil, actor: nil, notes: nil)
    @original_pay_period = original_pay_period
    @employee            = employee
    @corrected_inputs    = (corrected_inputs || {}).symbolize_keys
                                                  .slice(*CORRECTABLE_INPUT_FIELDS)
    @pay_date            = pay_date
    @reason              = reason
    @actor               = actor
    @notes               = notes
  end

  # Returns the original snapshot, the recomputed corrected snapshot, and
  # the deltas — without persisting anything. Used to drive the modal
  # preview before the operator commits.
  def preview
    validate_for_preview!
    {
      original:  snapshot(original_item),
      corrected: snapshot(corrected_item),
      deltas:    delta_hash,
      meta: {
        original_pay_period_id: @original_pay_period.id,
        original_payroll_item_id: original_item.id,
        employee_id: @employee.id,
        employee_name: @employee.full_name,
        will_generate_check: net_delta.positive?,
        is_zero_change: zero_change?
      }
    }
  end

  def issue!
    validate_for_issue!
    raise InvalidStateError, "Corrected inputs do not change anything" if zero_change?

    PayPeriod.transaction do
      # Lock the original to prevent a concurrent void/correction on top
      # of us. We also re-read the latest state under lock.
      locked_original = PayPeriod.lock("FOR UPDATE").find(@original_pay_period.id)
      assert_correctable!(locked_original)

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

      [supplemental, corrective_item]
    end
  end

  private

  # ---------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------
  def validate_for_preview!
    raise OriginalNotFoundError, "Original payroll item not found for employee in this pay period" if original_item.nil?

    if @employee.employment_type == "contractor"
      raise UnsupportedEmployeeError,
            "Contractors don't have a tax surface to correct; edit the contractor item directly"
    end
  end

  def validate_for_issue!
    validate_for_preview!
    raise ArgumentError, "reason is required" if @reason.blank?
    raise ArgumentError, "pay_date is required" if @pay_date.blank?
    assert_correctable!(@original_pay_period)
  end

  def assert_correctable!(period)
    unless period.can_issue_corrective_paycheck?
      raise InvalidStateError,
            "Pay period must be a regular committed (non-voided) period to issue a corrective paycheck"
    end
    if original_item.voided?
      raise InvalidStateError,
            "Cannot issue a corrective paycheck for an item whose original check is voided"
    end
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
    @corrected_item ||= build_and_calculate_corrected_item
  end

  def build_and_calculate_corrected_item
    temp = PayrollItem.new(
      employee_id:              @employee.id,
      company_id:               @original_pay_period.company_id,
      pay_period_id:            @original_pay_period.id, # for pay_date / tax year context
      employment_type:          original_item.employment_type,

      # Inputs: original values overlaid with operator-supplied corrections.
      pay_rate:                 corrected_input(:pay_rate, original_item.pay_rate),
      hours_worked:             corrected_input(:hours_worked, original_item.hours_worked),
      overtime_hours:           corrected_input(:overtime_hours, original_item.overtime_hours),
      holiday_hours:            corrected_input(:holiday_hours, original_item.holiday_hours),
      pto_hours:                corrected_input(:pto_hours, original_item.pto_hours),
      bonus:                    corrected_input(:bonus, original_item.bonus),
      reported_tips:            corrected_input(:reported_tips, original_item.reported_tips),
      tip_pool:                 corrected_input(:tip_pool, original_item.tip_pool),
      non_taxable_pay:          corrected_input(:non_taxable_pay, original_item.non_taxable_pay),
      additional_withholding:   corrected_input(:additional_withholding, original_item.additional_withholding),
      withholding_tax_override: original_item.withholding_tax_override, # not currently overridable
      custom_earnings:          corrected_input(:custom_earnings, original_item.custom_earnings),
      custom_columns_data:      corrected_input(:custom_columns_data, original_item.custom_columns_data),
      loan_deduction:           original_item.loan_deduction,
      import_source:            original_item.import_source
    )
    temp.pay_period = @original_pay_period

    # Stub YTD context to "as it was when the original was first calculated":
    # i.e. exclude the original item itself from the YTD aggregates. This
    # makes the recomputed taxes match what would have been withheld had
    # the corrected inputs been on the original run.
    with_ytd_excluding_original do
      PayrollCalculator.for(@employee, temp).calculate
    end

    temp
  end

  # Set the employee's @cached_ytd_gross / @cached_ytd_social_security to
  # the YTD figures excluding the original payroll item (so the
  # calculator's `ytd_gross_before` / `ytd_ss_before` use them instead of
  # querying). Restores the previous cache values afterwards.
  def with_ytd_excluding_original
    prev_gross = @employee.instance_variable_get(:@cached_ytd_gross)
    prev_ss    = @employee.instance_variable_get(:@cached_ytd_social_security)

    @employee.instance_variable_set(:@cached_ytd_gross, ytd_gross_excluding_original)
    @employee.instance_variable_set(:@cached_ytd_social_security, ytd_ss_excluding_original)

    yield
  ensure
    @employee.instance_variable_set(:@cached_ytd_gross, prev_gross)
    @employee.instance_variable_set(:@cached_ytd_social_security, prev_ss)
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

  def ytd_sum_excluding_original(column)
    pay_date = @original_pay_period.pay_date
    year = pay_date.year
    @employee.payroll_items
      .joins(:pay_period)
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
  def corrected_input(key, fallback)
    @corrected_inputs.key?(key) ? @corrected_inputs[key] : fallback
  end

  def snapshot(item)
    DELTA_OUTPUT_FIELDS.each_with_object({}) do |field, h|
      h[field] = item.public_send(field).to_f.round(4)
    end.merge(
      hours_worked:   item.hours_worked.to_f,
      overtime_hours: item.overtime_hours.to_f,
      holiday_hours:  item.holiday_hours.to_f,
      pto_hours:      item.pto_hours.to_f,
      bonus:          item.bonus.to_f,
      reported_tips:  item.reported_tips.to_f,
      pay_rate:       item.pay_rate.to_f,
      custom_earnings: Array(item.custom_earnings),
      custom_columns_data: item.custom_columns_data || {}
    )
  end

  def delta_hash
    DELTA_OUTPUT_FIELDS.each_with_object({}) do |field, h|
      h[field] = (corrected_item.public_send(field).to_f - original_item.public_send(field).to_f).round(2)
    end.merge(
      hours_worked_delta:   (corrected_item.hours_worked.to_f - original_item.hours_worked.to_f).round(2),
      overtime_hours_delta: (corrected_item.overtime_hours.to_f - original_item.overtime_hours.to_f).round(2),
      holiday_hours_delta:  (corrected_item.holiday_hours.to_f - original_item.holiday_hours.to_f).round(2),
      pto_hours_delta:      (corrected_item.pto_hours.to_f - original_item.pto_hours.to_f).round(2)
    )
  end

  def net_delta
    (corrected_item.net_pay.to_f - original_item.net_pay.to_f).round(2)
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
      correction_for_payroll_item_id:    original_item.id,
      correction_reason:                 @reason,

      # Hours/inputs are stored as deltas (so summing across the
      # original + supplemental yields the corrected totals).
      pay_rate:        original_item.pay_rate, # rate isn't a delta — keep for reporting
      hours_worked:    deltas[:hours_worked_delta],
      overtime_hours:  deltas[:overtime_hours_delta],
      holiday_hours:   deltas[:holiday_hours_delta],
      pto_hours:       deltas[:pto_hours_delta],

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

    # Only assign a check number if there's actually money to pay out.
    # Negative net (clawback) supplementals exist as accounting entries
    # but don't generate paper.
    items_needing_check = supplemental.payroll_items
      .where(check_number: nil)
      .select { |i| i.net_pay.to_f > 0 }
    supplemental.company.assign_check_numbers!(items_needing_check) if items_needing_check.any?

    # FIT auto-deposit: if there's a positive FIT delta and the company
    # has the auto-deposit setting on, generate the supplemental's own
    # FIT NonEmployeeCheck. Re-uses the existing controller method via
    # an inline implementation to avoid coupling. The unique-per-period
    # index on auto_generated_type guarantees no duplicates within the
    # supplemental period.
    create_supplemental_fit_check!(supplemental) if supplemental.company.auto_create_fit_check?

    # Tax sync — the supplemental gets its own idempotency key and is
    # pushed independently to the external tax service.
    supplemental.prepare_tax_sync!
    ActiveRecord.after_all_transactions_commit do
      PayrollTaxSyncJob.perform_later(supplemental.id)
    end
  end

  def create_supplemental_fit_check!(supplemental)
    fit_total = supplemental.payroll_items
      .where(employment_type: %w[hourly salary])
      .where(voided: false)
      .sum(:withholding_tax)

    return if fit_total.to_f <= 0 # no positive FIT delta → no deposit needed

    NonEmployeeCheck.create!(
      company_id:           supplemental.company_id,
      pay_period_id:        supplemental.id,
      created_by:           @actor,
      payable_to:           "Treasurer of Guam",
      amount:               fit_total,
      check_type:           "tax_deposit",
      auto_generated_type:  NonEmployeeCheck::AUTO_GENERATED_TYPES[:fit_deposit],
      memo:                 "FIT deposit for corrective paycheck (#{supplemental.start_date} – #{supplemental.end_date})",
      description:          "Federal Income Tax (FIT) — corrective deposit for #{@employee.full_name}"
    )
  end
end
