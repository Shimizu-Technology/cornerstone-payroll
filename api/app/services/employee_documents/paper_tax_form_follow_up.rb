# frozen_string_literal: true

module EmployeeDocuments
  module PaperTaxFormFollowUp
    DEADLINE_DAYS = 30
    SOFT_BOUNCES = %w[transient soft].freeze

    module_function

    # Called in the same transaction that applies the signed provider event,
    # under the notice row lock. Both the task and notification ledger commit
    # with the event, including when the periodic sweep matches it later.
    def record!(notice, event)
      return if notice.paper_due_on || event.delivery_status != "bounced"
      return if SOFT_BOUNCES.include?(event.bounce_type.to_s.downcase)
      return unless CompanyFeatures.for(notice.company).employee_portal_feature?(:tax_forms)
      return unless notice.kind == TaxFormNotice::KIND && consent_at_delivery?(notice, event)

      bounced_on = [ event.occurred_at, event.created_at ].min.in_time_zone(PayrollBusinessClock::TIME_ZONE).to_date
      notice.update!(paper_bounced_on: bounced_on, paper_due_on: bounced_on + DEADLINE_DAYS)
      PortalNotifications.record!(event_type: "tax_form_paper_required", company: notice.company,
        actor: nil, subject: notice, dedupe_key: "tax_form_paper_required:#{notice.id}",
        metadata: { employee_document_id: notice.employee_document_id, tax_year: notice.employee_document.tax_year })
    end

    def consent_at_delivery?(notice, event)
      delivery_at = notice.sent_at || event.occurred_at
      DeliveryConsent.for_kind("w2gu").where(company_id: notice.company_id, employee_id: notice.employee_id)
        .where(given_at: ..delivery_at).where("withdrawn_at IS NULL OR withdrawn_at > ?", delivery_at).exists?
    end
  end
end
