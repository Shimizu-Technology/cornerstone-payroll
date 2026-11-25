# frozen_string_literal: true

# Sends the "IMPORTANT TAX RETURN DOCUMENT AVAILABLE" email for one posted
# W-2GU copy (EmployeeDocuments::TaxFormNotice). A failed send is retried; a
# sent or skipped notice is never sent twice.
class SendEmployeeTaxFormNoticeJob < ApplicationJob
  self.rls_mode = :company

  queue_as :default
  class DeliveryFailed < StandardError; end

  retry_on DeliveryFailed, wait: :polynomially_longer, attempts: 5

  def perform(company_id, employee_document_id)
    document = EmployeeDocument.tax_forms.find_by(company_id: company_id, id: employee_document_id)
    return unless document

    notice = EmployeeDocuments::TaxFormNotice.deliver(document)
    raise DeliveryFailed, "Tax form notice #{notice.id} failed" if notice.status == "failed"
  end
end
