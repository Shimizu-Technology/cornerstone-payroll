# frozen_string_literal: true

class CheckPrintRunConfirmationService
  StaleSelectionError = CheckPrintRunSelectionVerifier::StaleSelectionError

  def initialize(run:, actor:, ip_address: nil)
    @run = run
    @actor = actor
    @ip_address = ip_address
  end

  def call
    result = nil

    CheckPrintRun.transaction do
      locked_run = CheckPrintRun.lock.find(run.id)
      if locked_run.confirmed?
        result = { run: locked_run, already_confirmed: true, marked_printed: 0 }
        next
      end

      locked_period = PayPeriod.lock.find(locked_run.pay_period_id)
      raise StaleSelectionError, "This pay period is no longer committed" unless locked_period.committed?
      if locked_run.company.require_distinct_check_print_confirmer? && locked_run.created_by_id == actor.id
        raise ArgumentError, "A different authorized payroll operator must confirm this print package"
      end

      payroll_items, non_employee_checks = CheckPrintRunSelectionVerifier.new(run: locked_run, lock: true).call

      payroll_items.values.each { |item| item.mark_printed!(user: actor, ip_address: ip_address) }
      non_employee_checks.values.each(&:mark_printed!)

      locked_run.update!(
        status: "confirmed",
        confirmed_at: Time.current,
        confirmed_by: actor
      )
      record_confirmation_audit!(locked_run, payroll_items.size, non_employee_checks.size)
      result = {
        run: locked_run,
        already_confirmed: false,
        marked_printed: payroll_items.size + non_employee_checks.size
      }
    end

    result
  end

  private

  attr_reader :run, :actor, :ip_address

  def record_confirmation_audit!(locked_run, employee_count, non_employee_count)
    AuditLog.record!(
      user: actor,
      organization_id: locked_run.company.organization_id,
      company_id: locked_run.company_id,
      action: "check_print_runs#confirmed",
      record_type: "check_print_runs",
      record_id: locked_run.id,
      subject_name: "Check package for #{locked_run.pay_period.start_date} through #{locked_run.pay_period.end_date}",
      metadata: {
        pay_period_id: locked_run.pay_period_id,
        selected_count: locked_run.selected_count,
        employee_check_count: employee_count,
        non_employee_check_count: non_employee_count,
        check_numbers: locked_run.manifest.map { |entry| entry.fetch("check_number") },
        starting_slot: locked_run.starting_slot,
        sha256: locked_run.sha256
      },
      ip_address: ip_address,
      event_category: "activity"
    )
  end
end
