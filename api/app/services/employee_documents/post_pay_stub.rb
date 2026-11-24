# frozen_string_literal: true

module EmployeeDocuments
  class PostPayStub
    def initialize(item, now: Time.current)
      @item = item
      @now = now
    end

    def call
      period = @item.pay_period
      period.with_lock("FOR SHARE") do
        @item.lock!
        @item.pay_period = period
        reconcile(period)
      end
    end

    private

    def reconcile(period)
      latest = documents_for(@item.id).lock.first
      unless period.committed? && @item.payroll_included?
        latest.update!(status: :withdrawn) if latest&.posted?
        return
      end
      return if latest&.replaced?
      return if @now < cutoff(period) || (period.committed_at && @now < period.committed_at) || paper_payment_waiting?
      return unless @item.employee&.company_id == @item.company_id
      return unless EarningsStatementEligibility.printable?(@item)

      payment_line = PayStubGenerator.employee_payment_line(@item)
      return if latest&.posted? && latest.payment_line == payment_line

      original = correction_source
      predecessor = latest || original
      document = FreezePdf.call(
        bytes: PayStubGenerator.new(@item, employee_copy: true).generate,
        source: @item, posted_at: Time.current, revision: (latest&.revision || 0) + 1,
        predecessor: predecessor, payment_line: payment_line
      )
      latest&.update!(status: :replaced)
      # A delta correction is a separate payment. Its original stays active
      # while the underlying original payroll obligation remains in force.
      if original && (@item.financial_correction_origin_item_id.present? || !original.payroll_item.payroll_included?)
        original.update!(status: :replaced)
      end
      enqueue_employee_pay_stub_notice(document) if predecessor.nil?
      document
    end

    def documents_for(item_id)
      EmployeeDocument.where(company_id: @item.company_id, payroll_item_id: item_id).order(revision: :desc)
    end

    def correction_source
      id = @item.financial_correction_origin_item_id || @item.correction_for_payroll_item_id
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
