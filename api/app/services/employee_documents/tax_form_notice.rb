# frozen_string_literal: true

require "cgi"

module EmployeeDocuments
  # The "IMPORTANT TAX RETURN DOCUMENT AVAILABLE" email for a posted W-2GU
  # copy (M4-5). The subject is the wording 26 CFR 31.6051-1(j) requires for
  # electronic furnishing; it's harmless while paper also goes out. The email
  # carries the employer's name and a link to the app, never an amount or an
  # SSN, and goes only to the employee's own verified employees.email, only
  # while they have app access. A demo company's notice goes only to an
  # allow-listed address (DemoOutbound).
  #
  # One EmployeeDocumentNotice row per document records the outcome. The
  # row is created "pending" in the same transaction that posts the copy
  # (ensure_pending!), so a crash before the email goes can't strand it;
  # DispatchEmployeeTaxFormNoticesJob sends pending rows and retries failed
  # ones. A sent notice's delivery_status stays "unknown" until a signed
  # provider event reports delivery or a bounce.
  module TaxFormNotice
    SUBJECT = "IMPORTANT TAX RETURN DOCUMENT AVAILABLE"
    KIND = "w2gu_available"
    CHANNEL = "employee_tax_form_notice"
    # A failed send is tried this many times in all, then left for staff.
    MAX_ATTEMPTS = 5

    module_function

    # Adds a pending notice for every posted copy of the year that has none
    # (a rerun of posting recovers any that are missing), and returns how
    # many of the year's notices are still unsent. Called inside the
    # posting transaction, under the company lock.
    def ensure_pending!(company:, tax_year:)
      documents = EmployeeDocument.tax_forms.posted.where(company_id: company.id, tax_year: tax_year)
      missing = documents.where.not(id: EmployeeDocumentNotice.where(company_id: company.id, kind: KIND).select(:employee_document_id))
        .order(:id).pluck(:id, :employee_id)
      if missing.any?
        now = Time.current
        EmployeeDocumentNotice.insert_all(missing.map do |document_id, employee_id|
          { company_id: company.id, employee_document_id: document_id, employee_id: employee_id, kind: KIND,
            status: "pending", created_at: now, updated_at: now }
        end, unique_by: :idx_employee_document_notices_once)
      end
      unsent(EmployeeDocumentNotice.where(company_id: company.id, employee_document_id: documents.select(:id))).count
    end

    # Notices the dispatcher should try: pending, or failed with tries left.
    def unsent(scope = EmployeeDocumentNotice.all)
      scope.where(kind: KIND).where(status: "pending").or(scope.where(kind: KIND, status: "failed").where(attempts: ...MAX_ATTEMPTS))
    end

    # Returns the notice row. A sent or skipped notice is never sent again;
    # a failed one is retried by the dispatcher.
    def deliver(document)
      notice = EmployeeDocumentNotice.create_or_find_by!(company_id: document.company_id, employee_document_id: document.id, kind: KIND) do |row|
        row.employee_id = document.employee_id
      end
      notice.with_lock do
        next if notice.status.in?(%w[sent skipped])
        next if notice.status == "failed" && notice.attempts >= MAX_ATTEMPTS

        document.reload
        if (reason = skip_reason(document))
          notice.update!(status: "skipped", skip_reason: reason)
          next
        end

        send!(notice, document)
      end
      # A delivery event can arrive before the provider id commits.
      NoticeDeliveryEvent.reconcile!(notice.provider_message_id) if notice.provider_message_id
      notice
    end

    def skip_reason(document)
      company = document.company
      employee = document.employee
      return "document_unavailable" unless document.tax_form? && document.posted? && employee
      return "feature_off" unless CompanyFeatures.for(company).employee_portal_feature?(:tax_forms)
      return "no_app_access" unless EmployeeAccountLink.portal_eligible.where(company_id: company.id, employee_id: employee.id).exists?
      return "email_not_verified" if employee.email.blank? || employee.email_verified_at.nil?
      return "email_delivery_disabled" unless PortalNotifications.delivery_enabled?
      return "email_not_configured" unless PortalNotifications::Transport.configured?
      return "recipient_not_allowed" unless DemoOutbound.permit?(company: company, email: employee.email, channel: CHANNEL)

      nil
    end

    def send!(notice, document)
      to = document.employee.email
      notice.update!(attempts: notice.attempts + 1, recipient_email: to)
      response = DemoOutbound.scoped(document.company) do
        PortalNotifications::Transport.deliver(payload(document, to), idempotency_key: "employee-tax-form-notice-#{document.id}")
      end
      if response["suppressed"]
        notice.update!(status: "skipped", skip_reason: "recipient_not_allowed")
        return
      end

      # Only a real provider id can be matched to a later delivery event.
      message_id = response["id"] unless response["captured"] || response["staging_captured"]
      notice.update!(status: "sent", sent_at: Time.current, provider_message_id: message_id.presence, skip_reason: nil)
    rescue StandardError => error
      Rails.logger.warn("[TaxFormNotice] Notice for employee document #{document.id} failed: #{error.class}")
      # Kept as failed (the lock's transaction still commits); the dispatcher retries.
      notice.update!(status: "failed")
    end

    def payload(document, to)
      employer = document.company.name
      origin = EmployeeLinks::AppUrl.origin_for(document.company)
      lines = [
        "Your #{document.tax_year} Form W-2GU from #{employer} is now available in your employee app.",
        (origin ? "Sign in to view or download it: #{origin}/taxes" : "Sign in to your employee app to view or download it."),
        "You'll also get a paper copy, the same way as other years. If you weren't expecting this email, contact #{employer}."
      ]
      {
        from: PortalNotifications::Transport.from_email, to: to, subject: SUBJECT,
        text: lines.join("\n\n"),
        html: lines.map { |line| "<p>#{CGI.escapeHTML(line)}</p>" }.join
      }
    end
  end
end
