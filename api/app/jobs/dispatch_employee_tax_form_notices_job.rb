# frozen_string_literal: true

# Sends pending W-2GU and pay-stub correction notices, retries failed
# sends, and reconciles stored provider delivery events.
# Posting enqueues it for one company after its rows commit; the recurring
# sweep (config/recurring.yml) runs it for every company, so a notice whose
# job was lost, or that failed, is still sent. Safe to run twice: a sent or
# skipped notice is never sent again, and the send uses an idempotency key.
class DispatchEmployeeTaxFormNoticesJob < ApplicationJob
  # Scoped in perform: one company's notices, or every company's for the sweep.
  self.rls_mode = nil

  queue_as :default
  retry_on ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout, wait: :polynomially_longer, attempts: 5

  BATCH = 200
  # A failed send waits at least this long before the sweep tries again.
  RETRY_AFTER = 10.minutes

  def perform(company_id = nil)
    return TenantScope.with_company(company_id) { dispatch(company_id) } if company_id

    TenantScope.as_system(reason: "Send pending employee document notices for every company") do
      sent = dispatch(nil)
      EmployeeDocuments::NoticeDeliveryEvent.sweep!
      sent
    end
  end

  private

  def dispatch(company_id)
    notice = EmployeeDocuments::TaxFormNotice
    notices = notice.unsent.or(notice.unsent(kind: notice::PAY_STUB_CORRECTED))
    notices = notices.where(company_id: company_id) if company_id
    # A failed send just now is left for a later sweep, not retried in a loop.
    notices = notices.where(status: "pending").or(notices.where(updated_at: ..RETRY_AFTER.ago))
    sent = 0
    notices.order(:id).limit(BATCH).pluck(:company_id, :employee_document_id, :kind).each do |notice_company_id, document_id, kind|
      document = EmployeeDocument.find_by(company_id: notice_company_id, id: document_id)
      next unless document

      if kind == notice::KIND
        notice.deliver(document)
      else
        notice.deliver(document, kind: kind)
      end
      sent += 1
    rescue StandardError => e
      Rails.logger.error("[DispatchEmployeeTaxFormNoticesJob] Notice for employee document #{document_id} failed: #{e.class}")
      Rails.error.report(e, handled: true, context: { employee_document_id: document_id })
    end
    sent
  end
end
