# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # The employee's own pay stubs (M4-4): posted frozen stubs and the
      # earlier QuickBooks checks, read through the link only. Behind the
      # company's employee_portal.features.stubs switch. Every failure,
      # including a switch that is off, is the same empty 404.
      class StatementsController < BaseController
        include EmployeePortalFrozenDocuments

        before_action :no_store, :require_stubs!

        AUDIT_ACTION = "employee_statement"
        YEAR = /\A(?:19|2\d)\d{2}\z/
        PAGE = /\A[1-9]\d{0,4}\z/

        # GET /api/v1/employee/statements?year=2026&page=1
        def index
          year = optional_param(:year, YEAR)
          page = optional_param(:page, PAGE) || 1
          return head :bad_request if year == :invalid || page == :invalid

          result = statements.page(year: year, page: page)
          previous = statements.previous_regular_by_id(result.statements)
          audit!("listed", record: @employee_link || @view_as_employee_context.link || employee_access_context.employee, metadata: { year: year, page: page, count: result.statements.size })
          render json: {
            statements: result.statements.map do |statement|
              EmployeeStatements::Presenter.new(statement, statements: statements, previous: previous[statement.id]).summary
            end,
            years: result.years,
            next_page: result.next_page
          }
        end

        # GET /api/v1/employee/statements/:id
        def show
          statement = statements.find(params[:id])
          return head :not_found unless statement

          previous = statements.previous_regular(statement.document) if statement.kind == :payroll
          payload = EmployeeStatements::Presenter.new(statement, statements: statements, previous: previous).detail
          record = statement.kind == :quickbooks ? statement.check : statement.document
          audit!("viewed", record: record, metadata: { source: payload[:source], statement_id: statement.id })
          render json: payload
        end

        # GET /api/v1/employee/statements/:id/pdf: the frozen file as posted.
        def pdf
          document = statements.pdf_document(params[:id])
          return head :not_found unless document

          bytes = stored_bytes(document)
          return head :service_unavailable unless bytes
          return head :not_found unless still_servable?(document, feature: :stubs) do |context, current|
            EmployeeStatements.new(context: context).pdf_document(params[:id])&.id == current.id
          end

          audit!("pdf_downloaded", record: document,
            metadata: { statement_id: params[:id].to_s, revision: document.revision, sha256: document.sha256 })
          response.headers["X-Content-Type-Options"] = "nosniff"
          send_data bytes, filename: pdf_filename(document), type: "application/pdf", disposition: "attachment"
        end

        private

        def require_stubs!
          head :not_found unless CompanyFeatures.for(employee_access_context.company).employee_portal_feature?(:stubs)
        end

        def statements
          @statements ||= EmployeeStatements.new(context: employee_access_context)
        end

        # nil when absent, :invalid when malformed, otherwise the integer.
        def optional_param(name, pattern)
          value = params[name]
          return nil if value.nil? || value == ""
          return :invalid unless value.is_a?(String) && value.match?(pattern)

          value.to_i
        end

        def pdf_filename(document)
          date = document.payroll_item&.pay_period&.pay_date || document.historical_paycheck&.pay_date
          "pay-stub-#{date&.iso8601 || document.id}#{'-corrected' if document.corrected}.pdf"
        end

        def audit!(event, record:, metadata: {})
          AuditLog.record!(
            actor: Current.actor, user: @current_user,
            organization_id: employee_access_context.company.organization_id, company_id: employee_access_context.company_id,
            action: "#{AUDIT_ACTION}##{event}", record_type: record.class.name, record_id: record.id,
            subject_name: employee_access_context.employee.display_name, event_category: "employee_portal",
            metadata: metadata.merge(employee_account_link_id: employee_access_context.id, employee_id: employee_access_context.employee_id).compact
          )
          skip_default_audit_log!
        end
      end
    end
  end
end
