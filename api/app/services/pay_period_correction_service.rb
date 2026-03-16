# frozen_string_literal: true

# CPR-71: Orchestrates the payroll-level correction lifecycle.
#
# Three operations are supported:
#
#   1. void!               – Void a committed pay period.
#      - Marks the period as voided (correction_status = 'voided').
#      - Reverses YTD totals for every employee and the company.
#      - Records a PayPeriodCorrectionEvent for the audit trail.
#      - Idempotency guard: raises if the period is already voided or has a correction run.
#
#   2. create_correction_run! – Create a new draft pay period that corrects a voided one.
#      - Validates the source period is voided and not already superseded.
#      - Creates a new 'draft' pay period with correction_status = 'correction'.
#      - Links the voided period ← superseded_by_id → new period.
#      - Copies payroll items from the source (so operators can adjust before re-running).
#      - Records a PayPeriodCorrectionEvent.
#
#   3. audit_trail         – Returns correction events for a given pay period,
#      including events where this period is the resulting period.
#
# All mutating operations run inside a transaction with explicit row-level
# locking (SELECT ... FOR UPDATE) on the pay period to prevent concurrent
# double-voids / duplicate correction-run creation.
class PayPeriodCorrectionService
  # Errors specific to correction workflow
  class CorrectionError < StandardError; end
  class AlreadyVoidedError       < CorrectionError; end
  class AlreadySupersededError   < CorrectionError; end
  class NotVoidedError           < CorrectionError; end
  class InvalidStateError        < CorrectionError; end

  # ----------------------------------------------------------------
  # void!
  # ----------------------------------------------------------------
  # @param pay_period [PayPeriod]   – must be committed and not already voided
  # @param actor      [User]        – user initiating the void
  # @param reason     [String]      – mandatory explanation
  # @return [PayPeriodCorrectionEvent]
  def self.void!(pay_period:, actor:, reason:)
    raise ArgumentError, "reason is required" if reason.blank?

    PayPeriod.transaction do
      # Acquire row lock to prevent concurrent void attempts
      locked = PayPeriod.lock("FOR UPDATE").find(pay_period.id)

      raise InvalidStateError, "Only committed pay periods can be voided" unless locked.committed?
      raise AlreadyVoidedError, "This pay period has already been voided" if locked.voided?
      raise AlreadySupersededError, "This pay period already has a correction run" if locked.superseded_by_id.present?

      was_correction_run = locked.correction_run?
      source_pay_period_id = locked.source_pay_period_id
      source_period = source_pay_period_id.present? ? PayPeriod.lock("FOR UPDATE").find(source_pay_period_id) : nil
      if was_correction_run && source_period.nil?
        raise InvalidStateError, "Correction run is missing source pay period linkage"
      end

      # Snapshot financials before mutation.
      # For a correction-run void, link the event to the source period while
      # snapshotting financials from the correction run being voided.
      event = PayPeriodCorrectionEvent.record!(
        action_type:    "void_initiated",
        pay_period:     source_period || locked,
        resulting_pay_period: (was_correction_run ? locked : nil),
        actor:          actor,
        reason:         reason,
        financial_snapshot_from: (was_correction_run ? :resulting_pay_period : :pay_period)
      )

      # Reverse all payroll items; paper-check void state must not affect payroll correction math.
      locked.payroll_items.find_each(batch_size: 500) do |item|
        reverse_ytd_for_item!(item, locked.pay_date.year, locked.company_id)
      end

      void_time = Time.current

      # Mark the pay period voided
      locked.update!(
        correction_status: "voided",
        voided_at:         void_time,
        voided_by_id:      actor&.id,
        void_reason:       reason,
        **locked.tax_sync_reset_attributes(reference_time: void_time)
      )

      # If a committed correction run is being voided, release source linkage so
      # operators can create another correction run from the original source.
      if was_correction_run && source_period.present?
        if source_period.superseded_by_id == locked.id
          source_period.update!(superseded_by_id: nil)
        end
      end

      event
    end
  end

  # ----------------------------------------------------------------
  # create_correction_run!
  # ----------------------------------------------------------------
  # @param source_pay_period [PayPeriod]  – must be voided and not yet superseded
  # @param actor             [User]
  # @param reason            [String]
  # @param new_start_date    [Date]       – optional; defaults to source dates
  # @param new_end_date      [Date]
  # @param new_pay_date      [Date]
  # @param notes             [String]
  # @return [PayPeriod]  the newly created correction run
  def self.create_correction_run!(
    source_pay_period:,
    actor:,
    reason:,
    new_start_date: nil,
    new_end_date:   nil,
    new_pay_date:   nil,
    notes:          nil
  )
    raise ArgumentError, "reason is required" if reason.blank?

    PayPeriod.transaction do
      locked_source = PayPeriod.lock("FOR UPDATE").find(source_pay_period.id)

      raise NotVoidedError,          "Source pay period must be voided before creating a correction run" unless locked_source.voided?
      raise AlreadySupersededError,  "Source pay period already has a correction run" if locked_source.superseded_by_id.present?

      # Build the new correction pay period
      correction_run = PayPeriod.create!(
        company_id:         locked_source.company_id,
        start_date:         new_start_date || locked_source.start_date,
        end_date:           new_end_date   || locked_source.end_date,
        pay_date:           new_pay_date   || locked_source.pay_date,
        status:             "draft",
        correction_status:  "correction",
        source_pay_period_id: locked_source.id,
        notes:              build_correction_notes(locked_source, reason, notes)
      )

      # Copy payroll items from the source so operators can adjust hours/amounts.
      # Items start with nil check_number, check_status = nil, voided = false.
      copy_payroll_items!(source: locked_source, target: correction_run)

      # Link the voided source period to the new correction run
      locked_source.update!(superseded_by_id: correction_run.id)

      # Audit
      PayPeriodCorrectionEvent.record!(
        action_type:           "correction_run_created",
        pay_period:            locked_source,
        resulting_pay_period:  correction_run,
        actor:                 actor,
        reason:                reason,
        extra_metadata: {
          created_correction_run_id: correction_run.id
        }
      )

      correction_run
    end
  end

  # ----------------------------------------------------------------
  # record_correction_committed!
  # Called from PayPeriodsController#commit for correction-run periods.
  # ----------------------------------------------------------------
  def self.record_correction_committed!(pay_period:, actor:, reason: "Correction run committed")
    source_id = pay_period.source_pay_period_id
    raise InvalidStateError, "Correction run is missing source pay period linkage" if source_id.nil?

    PayPeriod.transaction do
      source = PayPeriod.lock("FOR UPDATE").find(source_id)

      PayPeriodCorrectionEvent.record!(
        action_type:           "correction_run_committed",
        pay_period:            source,
        resulting_pay_period:  pay_period,
        actor:                 actor,
        reason:                reason,
        # Keep the canonical source-period linkage while capturing the
        # newly committed correction-run totals for audit completeness.
        financial_snapshot_from: :resulting_pay_period
      )
    end
  end

  # ----------------------------------------------------------------
  # audit_trail
  # Returns all correction events associated with a pay period,
  # whether as the primary period or as the resulting correction run.
  # ----------------------------------------------------------------
  def self.audit_trail(pay_period)
    PayPeriodCorrectionEvent
      .where(pay_period_id: pay_period.id)
      .or(PayPeriodCorrectionEvent.where(resulting_pay_period_id: pay_period.id))
      .includes(:actor, :pay_period, :resulting_pay_period)
      .chronological
  end

  # ----------------------------------------------------------------
  # Private helpers
  # ----------------------------------------------------------------
  private_class_method def self.reverse_ytd_for_item!(item, year, company_id)
    employee_ytd = EmployeeYtdTotal.find_by(
      employee_id: item.employee_id,
      year:        year
    )
    employee_ytd&.subtract_payroll_item!(item)

    company_ytd = CompanyYtdTotal.find_by(
      company_id: company_id,
      year:       year
    )
    company_ytd&.subtract_payroll_item!(item)
  end

  private_class_method def self.copy_payroll_items!(source:, target:)
    # Copy every payroll row into the correction run, even if the original paper
    # check was voided. Check voiding is an issuance/audit concern, not a payroll
    # inclusion flag, and operators need the employee row present so they can
    # recalculate or zero it out explicitly in the correction run.
    source.payroll_items.find_each(batch_size: 500) do |source_item|
      target.payroll_items.create!(
        employee_id:              source_item.employee_id,
        employment_type:          source_item.employment_type,
        pay_rate:                 source_item.pay_rate,
        hours_worked:             source_item.hours_worked,
        overtime_hours:           source_item.overtime_hours,
        holiday_hours:            source_item.holiday_hours,
        pto_hours:                source_item.pto_hours,
        bonus:                    source_item.bonus,
        reported_tips:            source_item.reported_tips,
        tip_pool:                 source_item.tip_pool,
        loan_deduction:           source_item.loan_deduction,
        additional_withholding:   source_item.additional_withholding,
        import_source:            source_item.import_source,
        custom_columns_data:      source_item.custom_columns_data
        # Calculated fields (gross_pay, taxes, etc.) start at zero —
        # operator must run Calculate Payroll to recompute.
      )
    end
  end

  private_class_method def self.build_correction_notes(source, reason, extra_notes)
    parts = [
      "Correction run for pay period ##{source.id} " \
      "(#{source.start_date} – #{source.end_date}): #{reason}"
    ]
    parts << extra_notes if extra_notes.present?
    parts.join("\n")
  end
end
