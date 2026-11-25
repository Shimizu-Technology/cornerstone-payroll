# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # The employee's own W-2GU copies (M4-5): the frozen Copy B and C posted
      # for each tax year, read through the link only. Behind the company's
      # employee_portal.features.tax_forms switch. A copy staff withdrew is
      # listed without a PDF, so the app can say a corrected form is being
      # prepared. A former link sees every copy posted for that employee, so
      # its read-only access covers each year they were paid. Every failure,
      # including a switch that is off, is the same empty 404.
      class TaxFormsController < BaseController
        include EmployeePortalFrozenDocuments

        before_action :no_store, :require_tax_forms!

        AUDIT_ACTION = "employee_tax_form"
        DOCUMENT_ID = /\A[1-9]\d{0,18}\z/

        # GET /api/v1/employee/tax_forms
        def index
          forms = visible_documents.to_a
          audit!("listed", record: @employee_link, metadata: { count: forms.size })
          render json: { tax_forms: forms.map { |document| summary(document) } }
        end

        # GET /api/v1/employee/tax_forms/:id
        def show
          document = find_document(visible_documents)
          return head :not_found unless document

          audit!("viewed", record: document, metadata: { tax_year: document.tax_year, status: document.status })
          render json: summary(document)
        end

        # GET /api/v1/employee/tax_forms/:id/pdf: the frozen file as posted.
        def pdf
          document = find_document(visible_documents.posted)
          return head :not_found unless document

          bytes = stored_bytes(document)
          return head :service_unavailable unless bytes
          return head :not_found unless still_servable?(document, feature: :tax_forms) do |link, current|
            current.tax_form? && current.posted? && current.employee_id == link.employee_id
          end

          audit!("pdf_downloaded", record: document,
            metadata: { tax_year: document.tax_year, revision: document.revision, sha256: document.sha256 })
          response.headers["X-Content-Type-Options"] = "nosniff"
          send_data bytes, filename: "w-2gu-#{document.tax_year}#{'-corrected' if document.corrected}.pdf",
            type: "application/pdf", disposition: "attachment"
        end

        private

        def require_tax_forms!
          head :not_found unless CompanyFeatures.for(@employee_link.company).employee_portal_feature?(:tax_forms)
        end

        # This employee's current copy for each year: posted, or withdrawn
        # while a corrected form is prepared. A replaced revision isn't listed.
        def visible_documents
          EmployeeDocument.tax_forms.where(company_id: @employee_link.company_id, employee_id: @employee_link.employee_id,
            status: %w[posted withdrawn]).order(tax_year: :desc, revision: :desc, id: :desc)
        end

        def find_document(scope)
          id = params[:id].to_s
          scope.find_by(id: id.to_i) if DOCUMENT_ID.match?(id)
        end

        def summary(document)
          {
            id: document.id.to_s,
            tax_year: document.tax_year,
            kind: "w2gu",
            status: document.status,
            corrected: document.corrected,
            posted_at: document.posted_at.iso8601,
            pdf_available: document.posted?,
            available_through: EmployeeDocuments::TaxFormRetention.available_through(document.tax_year).to_date.iso8601
          }
        end

        def audit!(event, record:, metadata: {})
          AuditLog.record!(
            actor: Current.actor, user: @current_user,
            organization_id: @employee_link.company.organization_id, company_id: @employee_link.company_id,
            action: "#{AUDIT_ACTION}##{event}", record_type: record.class.name, record_id: record.id,
            subject_name: @employee_link.employee.display_name, event_category: "employee_portal",
            metadata: metadata.merge(employee_account_link_id: @employee_link.id, employee_id: @employee_link.employee_id).compact
          )
          skip_default_audit_log!
        end
      end
    end
  end
end
