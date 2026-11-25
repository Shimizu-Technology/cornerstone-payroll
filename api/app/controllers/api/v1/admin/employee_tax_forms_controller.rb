# frozen_string_literal: true

module Api
  module V1
    module Admin
      # The selected client's W-2GU copies in the employee app (M4-5): what's
      # posted for a tax year and each notice's delivery, posting the year's
      # copies (an explicit staff action, run by an idempotent job), and
      # withdrawing a posted copy with a reason. Until W-2c exists, the app
      # then tells the employee a corrected form is being prepared. Paper
      # W-2s go out as usual either way.
      class EmployeeTaxFormsController < BaseController
        CAPABILITY = :manage_client_administration
        MAX_REASON = 500
        DOCUMENT_ID = /\A[1-9]\d{0,18}\z/
        BLOCKER_MESSAGES = {
          feature_off: "The employee app's tax forms are switched off for this client.",
          unsupported_year: "W-2GU copies can be posted for tax year #{W2GuOfficialCopies::SUPPORTED_TAX_YEARS.to_sentence} only.",
          not_filed: "Cornerstone does not file this year's W-2s for this client, so there are no copies to post.",
          not_final: "The W-2s aren't marked ready on the current figures, so the copies would print as drafts. Mark them ready first."
        }.freeze

        # GET /api/v1/admin/employee_tax_forms?year=2026
        def index
          year = tax_year_param
          return if performed?

          company = current_company
          snapshot = W2GuOfficialCopies.snapshot(company, year) if W2GuOfficialCopies.supported_tax_year?(year)
          blocker = posting_blocker(company, year, snapshot)
          documents = EmployeeDocument.tax_forms.where(company_id: company.id, tax_year: year)
            .includes(:employee, :withdrawn_by, notices: :paper_mailed_by).order(:employee_id, revision: :desc, id: :desc)
          @current_fingerprint = snapshot&.dig(:fingerprint)
          render json: {
            tax_year: year,
            can_post: blocker.nil?,
            blocker: blocker,
            blocker_message: blocker && BLOCKER_MESSAGES[blocker],
            w2_delivery: company.w2_delivery,
            available_through: EmployeeDocuments::TaxFormRetention.available_through(year).to_date.iso8601,
            documents: documents.map { |document| document_payload(document) }
          }
        end

        # POST /api/v1/admin/employee_tax_forms/post_copies { year }
        # Queues the posting job, which posts only copies still missing.
        def post_copies
          year = tax_year_param
          return if performed?

          company = current_company
          skip_default_audit_log!
          blocker = company.with_lock do
            revalidate_current_company_write_access!(company: company, capability: CAPABILITY)
            posting_blocker(company, year)
          end
          if blocker
            return render json: { error: BLOCKER_MESSAGES.fetch(blocker), blocker: blocker }, status: :unprocessable_entity
          end

          PostEmployeeW2GuCopiesJob.perform_later(company.id, year, current_user.id)
          audit!(company, "post_requested", record: company, metadata: { tax_year: year })
          render json: { queued: true, tax_year: year }, status: :accepted
        end

        # POST /api/v1/admin/employee_tax_forms/:id/withdraw { reason }
        def withdraw
          reason = params[:reason].to_s.squish
          if reason.blank? || reason.length > MAX_REASON
            return render json: { error: "Give a reason of up to #{MAX_REASON} characters" }, status: :unprocessable_entity
          end
          return head :not_found unless DOCUMENT_ID.match?(params[:id].to_s)

          company = current_company
          skip_default_audit_log!
          outcome = company.with_lock do
            revalidate_current_company_write_access!(company: company, capability: CAPABILITY)
            document = EmployeeDocument.tax_forms.lock.find_by(company_id: company.id, id: params[:id].to_i)
            next :not_found unless document
            next :not_posted unless document.posted?

            document.update!(status: :withdrawn, withdrawal_reason: "staff_withdrawn", withdrawal_note: reason,
              withdrawn_at: Time.current, withdrawn_by: current_user)
            audit!(company, "withdrawn", record: document,
              metadata: { tax_year: document.tax_year, employee_id: document.employee_id, reason: reason })
            document
          end
          return render json: { error: "Not found" }, status: :not_found if outcome == :not_found
          if outcome == :not_posted
            return render json: { error: "Only a posted copy can be withdrawn" }, status: :unprocessable_entity
          end

          render json: { document: document_payload(outcome) }
        end

        # POST /api/v1/admin/employee_tax_forms/:id/mark_paper_mailed
        def mark_paper_mailed
          return head :not_found unless DOCUMENT_ID.match?(params[:id].to_s)

          company = current_company
          skip_default_audit_log!
          document = company.with_lock do
            revalidate_current_company_write_access!(company: company, capability: CAPABILITY)
            copy = EmployeeDocument.tax_forms.find_by(company_id: company.id, id: params[:id])
            notice = copy&.notices&.lock&.find_by(kind: EmployeeDocuments::TaxFormNotice::KIND)
            next unless notice&.paper_due_on

            unless notice.paper_mailed_on
              date = PayrollBusinessClock.today
              notice.update!(paper_mailed_on: date, paper_mailed_by: current_user)
              audit!(company, "paper_mailed", record: copy, metadata: { notice_id: notice.id, mailed_on: date.iso8601 })
            end
            copy
          end
          return head :not_found unless document

          render json: { document: document_payload(document) }
        end

        private

        # nil when posting can run now. Reads the W-2 sign-off as the staff
        # download does; the posting job checks it all again under the lock.
        def posting_blocker(company, year, snapshot = nil)
          blocker = EmployeeDocuments::PostW2GuCopies.new(company: company, year: year).blocker
          return blocker if blocker

          snapshot ||= W2GuOfficialCopies.snapshot(company, year)
          return :not_filed unless snapshot[:cornerstone_files]

          :not_final unless snapshot[:final]
        end

        def tax_year_param
          year = params[:year].present? ? Integer(params[:year], exception: false) : PayrollBusinessClock.today.year - 1
          return year if year && year > 2000 && year <= Date.current.year + 1

          render json: { error: "year must be a valid 4-digit tax year" }, status: :unprocessable_entity
          nil
        end

        def document_payload(document)
          notice = document.notices.min_by(&:id)
          {
            id: document.id,
            employee_id: document.employee_id,
            employee_name: document.employee&.full_name,
            tax_year: document.tax_year,
            revision: document.revision,
            status: document.status,
            posted_at: document.posted_at.iso8601,
            withdrawn_at: document.withdrawn_at&.iso8601,
            withdrawn_by: document.withdrawn_by&.name,
            withdrawal_note: document.withdrawal_note,
            # The year's W-2 inputs no longer match the ones this copy was drawn
            # from: staff decide whether to withdraw it for a corrected form.
            inputs_changed_since_posting: inputs_changed?(document),
            paper_follow_up: paper_follow_up_payload(notice),
            notice: notice && {
              status: notice.status, skip_reason: notice.skip_reason, sent_at: notice.sent_at&.iso8601,
              delivery_status: notice.delivery_status, bounce_type: notice.bounce_type,
              delivery_event_at: notice.delivery_event_at&.iso8601
            }
          }
        end

        def paper_follow_up_payload(notice)
          return unless notice&.paper_due_on

          {
            status: notice.paper_follow_up_state, bounced_on: notice.paper_bounced_on.iso8601,
            due_on: notice.paper_due_on.iso8601, mailed_on: notice.paper_mailed_on&.iso8601,
            mailed_by: notice.paper_mailed_by&.name
          }
        end

        def inputs_changed?(document)
          return false unless document.posted? && @current_fingerprint && document.payroll_facts_sha256

          document.payroll_facts_sha256 != @current_fingerprint
        end

        def audit!(company, event, record:, metadata:)
          AuditLog.record!(
            user: current_user, company_id: company.id, organization_id: company.organization_id,
            action: "employee_tax_forms##{event}", record_type: record.class.name, record_id: record.id,
            subject_name: company.name, event_category: "employee_portal", metadata: metadata,
            ip_address: request.remote_ip, user_agent: request.user_agent, request_id: request.request_id
          )
        end
      end
    end
  end
end
