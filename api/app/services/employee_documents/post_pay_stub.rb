# frozen_string_literal: true

module EmployeeDocuments
  class PostPayStub
    Posting = Data.define(:latest, :original, :predecessor, :fingerprint, :payment_line) do
      def revision
        (latest&.revision || 0) + 1
      end

      def ordinary_repost?
        predecessor && original.nil? && predecessor.withdrawal_reason.nil? && !predecessor.withdrawn?
      end

      def signature
        [ latest&.id, original&.id, predecessor&.id, revision, fingerprint, payment_line, ordinary_repost? ]
      end
    end

    def initialize(item, now: Time.current, notice_since: nil)
      @item = item
      @now = now
      @notice_since = notice_since
    end

    def call
      # An intervening payroll change can invalidate the staged PDF. Retry once
      # with fresh facts; the next sweep can handle sustained contention.
      2.times do
        result = post_once
        return result unless result == :stale
      end
      nil
    end

    private

    def post_once
      checked_at = Time.current
      prepared = with_locked_item do |period|
        generator = PayStubGenerator.new(@item, employee_copy: true)
        posting = posting_plan(period, generator, checked_at: checked_at)
        [ posting, generator.generate ] if posting
      end
      return unless prepared

      posting, bytes = prepared
      figures = PrintedFigures.digest(bytes)
      money_changed = (PrintedFigures.for_document(posting.predecessor) != figures) if posting.ordinary_repost?
      recorded = false
      staged = FreezePdf.stage(bytes: bytes, source: @item, revision: posting.revision)
      checked_at = Time.current
      with_locked_item do |period|
        current = posting_plan(period, PayStubGenerator.new(@item, employee_copy: true), checked_at: checked_at)
        next unless current
        next :stale unless current.signature == posting.signature

        document = record_posting(staged, current, period, checked_at, figures, money_changed)
        EmployeeDocument.current_transaction.after_rollback { FreezePdf.remove_uncommitted_object(staged.key) }
        recorded = true
        document
      end
    ensure
      FreezePdf.remove_uncommitted_object(staged.key) if staged && !recorded
    end

    # Locks in the order every payroll change takes them: company, then pay
    # period, then paycheck. The company lock is the one the new document's
    # foreign key needs; taking it first means a replacement or commit that
    # already holds the company never waits on a paycheck this posting holds.
    def with_locked_item
      # Rails bypasses the cache for locked queries, but the generator also
      # reads components and earlier paychecks that can change during upload.
      ActiveRecord::Base.uncached do
        EmployeeDocument.transaction(requires_new: true) do
          company = Company.lock("FOR KEY SHARE").find(@item.company_id)
          period = PayPeriod.lock("FOR SHARE").find(@item.pay_period_id)
          period.company = company
          @item = PayrollItem.eager_load(:employee).lock("FOR UPDATE OF payroll_items").find(@item.id)
          @item.pay_period = period
          @item.company = company
          yield period
        end
      end
    end

    def posting_plan(period, generator, checked_at:)
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
      fingerprint = generator.employee_payroll_facts_sha256
      if latest&.posted? && !repairing_link && generator.matches_employee_payroll_facts?(latest.payroll_facts_sha256)
        latest.update!(payroll_facts_checked_at: checked_at)
        return
      end

      Posting.new(latest: latest, original: original, predecessor: repairing_link ? original : (latest || original),
        fingerprint: fingerprint, payment_line: PayrollPaymentLabel.statement_line(@item))
    end

    def record_posting(staged, posting, period, checked_at, figures, money_changed)
      document = FreezePdf.record_staged!(staged, source: @item, posted_at: Time.current, revision: posting.revision,
        predecessor: posting.predecessor, payment_line: posting.payment_line,
        payroll_facts: { payroll_facts_sha256: posting.fingerprint, payroll_facts_checked_at: checked_at, printed_figures_sha256: figures, money_changed: money_changed })
      posting.latest&.update!(status: :replaced)
      # A delta correction is a separate payment. Its original stays active
      # while the underlying original payroll obligation remains in force.
      posting.original&.update!(status: :replaced) unless @item.correction_entry?
      if money_changed || (posting.predecessor.nil? && @notice_since && period.pay_date >= @notice_since)
        enqueue_employee_pay_stub_notice(document)
      end
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
      origins = PayrollItem.where(company_id: @item.company_id, employee_id: @item.employee_id)
      10.times do
        break unless id

        document = documents_for(id).where(payroll_item_id: origins.select(:id)).lock.first
        return document if document

        id = origins.where(id: id).pick(:financial_correction_origin_item_id)
      end
      nil
    end

    def cutoff(period)
      date = period.pay_date
      Time.find_zone!(PayStubGenerator::GUAM_TIME_ZONE).local(date.year, date.month, date.day, 6)
    end

    def paper_payment_waiting?
      @item.net_pay.to_d.positive? && @item.effective_payment_delivery_method == "paper_check" && @item.check_number.blank?
    end

    def enqueue_employee_pay_stub_notice(document)
      # Initial availability notices remain reserved for D11.
      return unless document.correction_label?

      EmployeeDocumentNotice.create!(company_id: document.company_id, employee_document: document,
        employee_id: @item.employee_id, kind: TaxFormNotice::PAY_STUB_CORRECTED, status: "pending")
    end
  end
end
