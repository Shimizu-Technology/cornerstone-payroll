# frozen_string_literal: true

module PayrollImport
  # Staff remove a worker from a run after the import, then add them back.
  # Brings back what the current applied import wrote for them besides hours
  # (tips, the workbook loan, bonus and one-time items), with the same checks
  # apply uses. Anything that can't be brought back safely is left out and
  # listed, by name and amount, with what staff should do instead. A loan that
  # Employee Loans may deduct on its own is never sent to hand entry. The
  # caller holds the company and pay-run locks.
  class AddBackRestore
    AUDIT_ACTION = "pay_period_excluded_employees#destroy"
    WHERE_TO_ENTER = {
      "loan" => "Enter it under Hours → Tips & Deductions.",
      "tips" => "Enter them under Hours → Tips & Deductions.",
      "bonus" => "Enter it in the Hours worksheet.",
      "component" => "Add it in Edit payroll.",
      "period_pay" => "Enter Pay this period in Expected entries."
    }.freeze

    # The latest add-back result for each worker still in the run, as its
    # audit entry recorded it. An import applied afterwards replaces it.
    def self.recent(pay_period)
      excluded = pay_period.pay_period_excluded_employees.pluck(:employee_id).to_set
      applied_at = pay_period.payroll_intake_sessions.where(status: "applied").maximum(:applied_at)
      logs = AuditLog.where(company_id: pay_period.company_id, action: AUDIT_ACTION, record_type: "PayPeriod", record_id: pay_period.id)
      logs = logs.where("created_at > ?", applied_at) if applied_at
      logs.order(:id).each_with_object({}) do |log, results|
        employee_id = log.metadata["employee_id"].to_i
        next if excluded.include?(employee_id)

        results[employee_id] = { employee_id: employee_id, employee_name: log.subject_name, import_id: log.metadata["import_id"],
          restored: Array(log.metadata["restored_import_amounts"]), not_restored: Array(log.metadata["not_restored_import_amounts"]) }
      end
    end

    def initialize(pay_period:, employee:, actor:)
      @pay_period = pay_period
      @employee = employee
      @actor = actor
      @skipped = {}
    end

    # Returns nil when the current applied import didn't pay this worker.
    def call
      return unless import_record && source_row

      if superseded?
        candidates.each do |candidate|
          if candidate[:kind] == "scheduled_loan" || (candidate[:kind] == "loan" && !employee_loans_deduct_nothing?)
            skip!(candidate, "The import was replaced by newer files. #{employee_loans_guidance}", by_hand: employee_loans_deduct_nothing?, next_step: nil)
          else
            skip!(candidate, "The import was replaced by newer files. Apply the current import review, or enter it by hand.", by_hand: true)
          end
        end
      elsif @pay_period.payroll_items.exists?(employee_id: @employee.id)
        candidates.each do |candidate|
          skip!(candidate, "#{@employee.full_name} already has a payroll row in this run. Check that row's amounts instead of entering these again.")
        end
      else
        restore!
      end
      result
    end

    private

    def import_record
      return @import_record if defined?(@import_record)

      @import_record = PayrollImportRecord.where(pay_period: @pay_period, status: "applied")
        .where.not(payroll_intake_session_id: nil).order(:id).last
    end

    def session
      import_record.payroll_intake_session
    end

    # The row the import applied: included, matched to this worker, applied.
    def source_row
      return @source_row if defined?(@source_row)

      applied = session.rows.exists?(employee_id: @employee.id, disposition: "included", status: "applied")
      row = applied && import_record.matched_data.find { |candidate| candidate["employee_id"].to_i == @employee.id }
      @source_row = row ? row.deep_symbolize_keys : nil
    end

    def superseded?
      session.superseded? ||
        @pay_period.payroll_intake_sessions.where(source_type: session.source_type)
          .where("package_revision > ?", session.package_revision).exists?
    end

    # Everything the import wrote for this worker besides hours, keyed so
    # each can be left out on its own.
    def candidates
      @candidates ||= begin
        rows = []
        rows << entry("loan", "loan", "Loan", source_row[:loan_deduction]) if money(source_row[:loan_deduction]).positive?
        Array(source_row[:loan_reconciliation_matches]).each do |match|
          rows << entry("scheduled_loan:#{match[:employee_loan_id]}", "scheduled_loan", match[:name].presence || "Scheduled loan", match[:amount])
        end
        rows << entry("tips", "tips", "Tips", source_row[:total_tips]) if money(source_row[:total_tips]).positive?
        rows << entry("bonus", "bonus", "Bonus", source_row[:bonus]) if money(source_row[:bonus]).positive?
        components.each_with_index do |component, index|
          rows << entry("component:#{index}", "component", component[:label].presence || "One-time item", component[:amount])
        end
        rows << entry("period_pay", "period_pay", "Pay this period", source_row[:period_pay]) if money(source_row[:period_pay]).positive?
        rows
      end
    end

    def restore!
      row = source_row.deep_dup
      unless loans_unchanged?
        # Employee Loans decides this payday's loan now; nothing from the
        # workbook loan is written to the row.
        row[:loan_deduction] = 0
        row[:loan_reconciliation_matches] = []
        # Hand entry is offered only when Employee Loans deducts nothing.
        candidates.select { |candidate| candidate[:kind].in?(%w[loan scheduled_loan]) }
          .each { |candidate| skip!(candidate, "#{@loan_reason} #{employee_loans_guidance}", by_hand: employee_loans_deduct_nothing?, next_step: nil) }
      end
      kept_components = components.each_with_index.filter_map do |component, index|
        error = import_service.component_error(component)
        next component unless error

        skip!(candidates.find { |candidate| candidate[:key] == "component:#{index}" }, error, by_hand: true)
        nil
      end
      row[:payroll_components] = kept_components
      # A client revision can change Pay this period after the workbook was
      # read, so the workbook amount is never restored.
      candidates.select { |candidate| candidate[:kind] == "period_pay" }
        .each { |candidate| skip!(candidate, "Pay this period isn't brought back from the import.", by_hand: true) }
      row[:period_pay] = nil
      row[:period_pay_evidence] = nil

      pending = candidates.reject { |candidate| @skipped.key?(candidate[:key]) }
      return if pending.empty?

      begin
        PayrollItem.transaction(requires_new: true) do
          import_service.restore_without_hours!(
            employee: @employee, row: row, tips_paid_out_from_tips: tips_paid_out_from_tips?,
            evidence: { import_id: import_record.id, added_back_at: Time.current.iso8601, added_back_by_id: @actor&.id }
          )
        end
      rescue ArgumentError, ActiveRecord::RecordInvalid => e
        pending.each { |candidate| skip!(candidate, e.message) }
      end
    end

    # The workbook loan is restored only when Employee Loans reconciles it
    # exactly as it did at import. A paused, new or changed loan is left for
    # staff to check in Employee Loans.
    def loans_unchanged?
      return true if candidates.none? { |candidate| candidate[:kind].in?(%w[loan scheduled_loan]) }

      now = LoanReconciliation.new(employee: @employee, pay_date: @pay_period.pay_date, source_row: loan_source_row).call
      same = money(now[:direct_loan_deduction]) == money(source_row[:loan_deduction]) &&
        loan_matches(now[:matches]) == loan_matches(source_row[:loan_reconciliation_matches])
      @loan_reason = now[:errors].first || ("Employee Loans changed since the import." unless same)
      @loan_reason.nil?
    end

    # What Employee Loans takes on its own this payday, against the workbook.
    # When it takes something, entering the workbook loan as well could deduct
    # it twice. When it takes nothing, staff either resume the loan or, for a
    # one-time amount, enter it by hand.
    def employee_loans_guidance
      loans = scheduled_loans
      amount = loans.sum { |loan| scheduled_amount(loan) }
      workbook = currency(loan_source_row[:loan_deduction])
      if employee_loans_deduct_nothing?
        return "Employee Loans will deduct nothing this payday; the workbook says #{workbook}. Resume the loan in Employee Loans, " \
          "or, if the workbook amount really is one-time this period, enter it under Hours → Tips & Deductions."
      end

      deducts = if amount.positive?
        "Employee Loans will deduct #{currency(amount)} this payday (#{loans.map(&:name).to_sentence})"
      else
        "#{@employee.full_name}'s payroll setup already deducts a loan this payday"
      end
      "#{deducts}; the workbook says #{workbook}. Check it in Employee Loans. Don't enter the workbook loan by hand."
    end

    def employee_loans_deduct_nothing?
      scheduled_loans.none? && !loan_setup_due?
    end

    def scheduled_loans
      return [] unless @pay_period.recurring_items_enabled?

      @employee.employee_loans.select { |loan| loan.active? && loan.repayment_schedule_active_on?(@pay_period.pay_date) && scheduled_amount(loan).positive? }
    end

    def scheduled_amount(loan)
      loan.scheduled_payment_for(pay_date: @pay_period.pay_date, requested_amount: loan.payment_amount || 0).to_d
    end

    def loan_setup_due?
      return @loan_setup_due if defined?(@loan_setup_due)

      @loan_setup_due = import_service.loan_setup_due?(@employee)
    end

    # The workbook's loan columns as the import read them.
    def loan_source_row
      values = source_row.slice(:one_payroll_deduction, :recurring_loan_deduction, :installment_payment,
        :installment_beginning_balance, :installment_new_amount, :installment_estimated_ending_balance)
      values.merge(loan_deduction: values.values_at(:one_payroll_deduction, :recurring_loan_deduction, :installment_payment).sum { |value| money(value) })
    end

    def loan_matches(matches)
      Array(matches).map { |match| match.to_h.symbolize_keys }.map { |match| [ match[:employee_loan_id].to_i, money(match[:amount]) ] }.sort
    end

    def components
      Array(source_row[:payroll_components])
    end

    def tips_paid_out_from_tips?
      ActiveModel::Type::Boolean.new.cast(import_record.raw_data.to_h.fetch("tips_paid_out_from_tips", false))
    end

    def import_service
      @import_service ||= ImportService.new(@pay_period, actor: @actor)
    end

    def entry(key, kind, label, amount)
      { key: key, kind: kind, label: label, amount: money(amount).to_s("F") }
    end

    # by_hand: the reason tells staff they may enter this amount themselves.
    # next_step defaults to where to enter it; pass nil when the reason says so.
    def skip!(candidate, reason, by_hand: false, next_step: WHERE_TO_ENTER[candidate[:kind]])
      return if @skipped.key?(candidate[:key])

      next_step = nil unless by_hand
      @skipped[candidate[:key]] = { reason: [ reason.to_s.strip, next_step ].compact.join(" "), enter_by_hand: by_hand }
    end

    def money(value)
      BigDecimal(value.to_s.presence || "0", exception: false)&.round(2) || 0.to_d
    end

    def currency(value)
      format("$%.2f", value.to_d)
    end

    def result
      present = ->(candidate) { candidate.slice(:key, :kind, :label, :amount) }
      { employee_id: @employee.id, employee_name: @employee.full_name, import_id: import_record.id,
        restored: candidates.reject { |candidate| @skipped.key?(candidate[:key]) }.map(&present),
        not_restored: candidates.select { |candidate| @skipped.key?(candidate[:key]) }
          .map { |candidate| present.call(candidate).merge(@skipped.fetch(candidate[:key])) } }
    end
  end
end
