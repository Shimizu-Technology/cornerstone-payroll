# frozen_string_literal: true

module Api
  module V1
    module Admin
      class QuickbooksStubUploadsController < BaseController
        before_action :require_historical_payroll_enabled!
        before_action :require_employee_stubs!

        rescue_from EmployeeDocuments::QuickbooksStubPdf::Invalid, EmployeeDocuments::ReviewQuickbooksStubs::Invalid do |error|
          audit_step("#{action_name}_rejected")
          render json: { error: error.message }, status: :unprocessable_entity
        end

        rescue_from R2StorageService::ConfigurationError, R2StorageService::UploadError do
          audit_step("storage_failed")
          render json: { error: "Document storage is unavailable. Try again." }, status: :service_unavailable
        end

        def preview
          response.headers["Cache-Control"] = "no-store"
          audit_step("upload")
          pages = review.preview
          audit_step("preview", { results: pages.pluck(:status).tally })
          render json: { data: pages }
        end

        def confirm
          tokens = params[:review_tokens]
          unless tokens.is_a?(Array) && tokens.size.between?(1, EmployeeDocuments::QuickbooksStubPdf::MAX_PAGES) &&
              tokens.all? { |token| token.is_a?(String) && token.bytesize <= 2.kilobytes }
            raise EmployeeDocuments::ReviewQuickbooksStubs::Invalid, "Select pages from the current preview."
          end

          response.headers["Cache-Control"] = "no-store"
          audit_step("confirm_requested", { page_count: tokens.size })
          documents = EmployeeDocument.transaction do
            current_company.lock!
            revalidate_current_company_write_access!
            unless CompanyFeatures.for(current_company).employee_portal_feature?(:stubs)
              raise CompanyWriteAccessChanged
            end

            review.confirm(tokens).tap do |frozen|
              audit_step("confirmed", { document_ids: frozen.map(&:id) })
            end
          end
          render json: { data: documents.map { |document| { document_id: document.id, historical_paycheck_id: document.historical_paycheck_id } } }
        end

        private

        def require_employee_stubs!
          return if current_company && CompanyFeatures.for(current_company).employee_portal_feature?(:stubs)

          render json: { error: "Employee pay stubs are unavailable for this client." }, status: :forbidden
        end

        def review
          EmployeeDocuments::ReviewQuickbooksStubs.new(company: current_company, actor: current_user, upload: params[:upload])
        end

        def audit_step(step, metadata = {})
          AuditLog.record!(
            user: current_user, company_id: current_company_id,
            organization_id: current_company.organization_id, action: "quickbooks_stub_uploads##{step}",
            record_type: "employee_documents", metadata: metadata, event_category: "employee_portal"
          )
        end
      end
    end
  end
end
