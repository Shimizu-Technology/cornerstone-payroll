# frozen_string_literal: true

module EmployeeDocuments
  class PostPayStub
    def initialize(item, now: Time.current, notice_since: nil)
      @item = item
      @now = now
      @notice_since = notice_since
    end

    # Locks in the order every payroll change takes them: company, then pay
    # period, then paycheck. The company lock is the one the new document's
    # foreign key needs; taking it first means a replacement or commit that
    # already holds the company never waits on a paycheck this posting holds.
    def call
      EmployeeDocument.transaction(requires_new: true) do
        company = Company.lock("FOR KEY SHARE").find(@item.company_id)
        period = PayPeriod.lock("FOR SHARE").find(@item.pay_period_id)
        period.company = company
        @item = PayrollItem.eager_load(:employee).lock("FOR UPDATE OF payroll_items").find(@item.id)
        @item.pay_period = period
        @item.company = company
        reconcile(period)
      end
    end

    private

    def reconcile(period)
      latest = documents_for(@item.id).lock.first
      if (reason = withdrawal_reason(period))
        latest.update!(status: :withdrawn, withdrawal_reason: reason) if latest&.posted?
        return
      end
      return if latest&.replaced?
      return if @now < cutoff(period) || (period.committed_at && @now < period.committed_at) || paper_payment_waiting?
      return unless @item.employee&.company_id == @item.company_id
      return unless EarningsStatementEligibility.printable?(@item)

      delta = @item.correction_entry?
      original = correction_source
      if delta && original.nil?
        Rails.logger.info("Employee pay stub waiting for origin document for payroll item #{@item.id}")
        return
      end

      repairing_link = delta && latest && latest.replaces_document_id.nil?
      checked_at = Time.current
      generator = PayStubGenerator.new(@item, employee_copy: true)
      fingerprint = generator.employee_payroll_facts_sha256
      if latest&.posted? && !repairing_link && latest.payroll_facts_sha256 == fingerprint
        latest.update!(payroll_facts_checked_at: checked_at)
        return
      end

      predecessor = repairing_link ? original : (latest || original)
      document = FreezePdf.call(
        bytes: generator.generate,
        source: @item, posted_at: Time.current, revision: (latest&.revision || 0) + 1,
        predecessor: predecessor, payment_line: PayStubGenerator.employee_payment_line(@item),
        payroll_facts: { payroll_facts_sha256: fingerprint, payroll_facts_checked_at: checked_at }
      ) do |key|
        EmployeeDocument.current_transaction.after_rollback { FreezePdf.remove_uncommitted_object(key) }
      end
      latest&.update!(status: :replaced)
      # A delta correction is a separate payment. Its original stays active
      # while the underlying original payroll obligation remains in force.
      original.update!(status: :replaced) if original && !delta
      enqueue_employee_pay_stub_notice(document) if predecessor.nil? && @notice_since && period.pay_date >= @notice_since
      document
    end

    def withdrawal_reason(period)
      return "reversal" unless @item.payroll_included?
      return "uncommitted" unless period.committed?
      return "void" if @item.voided?

      nil
    end

    def documents_for(item_id)
      EmployeeDocument.where(company_id: @item.company_id, payroll_item_id: item_id).order(revision: :desc)
    end

    def correction_source
      if @item.correction_entry?
        return documents_for(@item.correction_for_payroll_item_id).posted.lock.first
      end

      id = @item.financial_correction_origin_item_id
      documents_for(id).lock.first if id
    end

    def cutoff(period)
      date = period.pay_date
      Time.find_zone!(PayStubGenerator::GUAM_TIME_ZONE).local(date.year, date.month, date.day, 6)
    end

    def paper_payment_waiting?
      @item.net_pay.to_d.positive? && @item.effective_payment_delivery_method == "paper_check" && @item.check_number.blank?
    end

    def enqueue_employee_pay_stub_notice(_document)
      # D11 will enqueue the notice after the first posting commits.
    end
  end
end
