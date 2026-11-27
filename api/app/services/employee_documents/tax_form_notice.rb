# frozen_string_literal: true

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
    PAY_STUB_CORRECTED = "pay_stub_corrected"
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
    def unsent(scope = EmployeeDocumentNotice.all, kind: KIND)
      scope.where(kind: kind).where(status: "pending").or(scope.where(kind: kind, status: "failed").where(attempts: ...MAX_ATTEMPTS))
    end

    # Returns the notice row. A sent or skipped notice is never sent again;
    # a failed one is retried by the dispatcher.
    def deliver(document, kind: KIND)
      notice = EmployeeDocumentNotice.create_or_find_by!(company_id: document.company_id, employee_document_id: document.id, kind: kind) do |row|
        row.employee_id = document.employee_id || document.payroll_item.employee_id
      end
      notice.with_lock do
        next if notice.status.in?(%w[sent skipped])
        next if notice.status == "failed" && notice.attempts >= MAX_ATTEMPTS

        document.reload
        if (reason = skip_reason(document, kind: kind))
          notice.update!(status: "skipped", skip_reason: reason)
          next
        end

        send!(notice, document)
      end
      # A delivery event can arrive before the provider id commits.
      NoticeDeliveryEvent.reconcile!(notice.provider_message_id) if notice.provider_message_id
      notice
    end

    def skip_reason(document, kind: KIND)
      company = document.company
      employee = document_employee(document)
      eligible = kind == KIND ? document.tax_form? : document.payroll_item && document.correction_label?
      return "document_unavailable" unless eligible && document.posted? && employee&.company_id == company.id
      feature = kind == KIND ? :tax_forms : :stubs
      return "feature_off" unless CompanyFeatures.for(company).employee_portal_feature?(feature)
      return "no_app_access" unless EmployeeAccountLink.portal_eligible.where(company_id: company.id, employee_id: employee.id).exists?
      return "email_not_verified" if employee.email.blank? || employee.email_verified_at.nil?
      return "email_delivery_disabled" unless PortalNotifications.delivery_enabled?
      return "email_not_configured" unless PortalNotifications::Transport.configured?
      return "recipient_not_allowed" unless DemoOutbound.permit?(company: company, email: employee.email, channel: channel_for(kind))

      nil
    end

    def send!(notice, document)
      kind = notice.kind
      to = document_employee(document).email
      notice.update!(attempts: notice.attempts + 1, recipient_email: to)
      response = DemoOutbound.scoped(document.company, channel: channel_for(kind)) do
        PortalNotifications::Transport.deliver(payload(document, to, kind: kind), idempotency_key: "#{channel_for(kind).dasherize}-#{document.id}")
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

    def document_employee(document)
      document.employee || document.payroll_item&.employee
    end

    def channel_for(kind)
      kind == KIND ? CHANNEL : "employee_pay_stub_notice"
    end

    def payload(document, to, kind: KIND)
      brand = EmployeeEmails::Brand.for(document.company)
      if kind == PAY_STUB_CORRECTED
        origin = EmployeeLinks::AppUrl.origin_for(document.company)
        return EmployeeEmails::Message.new(brand: brand, subject: "Your pay stub was corrected",
          heading: "Your pay stub was corrected",
          paragraphs: [ "Sign in to your employee app to view the updated pay stub." ],
          action: (origin && { label: "Open the employee app", url: "#{origin}/pay" })).payload(to: to)
      end

      message(brand, tax_year: document.tax_year, employer: document.company.name,
        app_url: EmployeeLinks::AppUrl.origin_for(document.company)).payload(to: to)
    end

    # The notice's sentences are its approved wording; keep them word for
    # word. The button opens the app's tax forms page, never a document.
    def message(brand, tax_year:, employer:, app_url:)
      available = "Your #{tax_year} Form W-2GU from #{employer} is now available in your employee app."
      paper = "You'll also get a paper copy, the same way as other years. If you weren't expecting this email, contact #{employer}."
      taxes_url = "#{app_url}/taxes" if app_url
      EmployeeEmails::Message.new(
        brand: brand,
        subject: SUBJECT,
        heading: "Important tax return document available",
        paragraphs: [ available, ("Sign in to your employee app to view or download it." unless taxes_url) ].compact,
        action: (taxes_url && {
          label: "Open the employee app", url: taxes_url, lead: "Sign in to view or download it.",
          text_line: "Sign in to view or download it: #{taxes_url}"
        }),
        closing: [ paper ],
        preheader: "Your #{tax_year} Form W-2GU is ready in your employee app."
      )
    end
  end
end
