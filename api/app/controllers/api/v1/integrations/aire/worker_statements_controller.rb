# frozen_string_literal: true

module Api
  module V1
    module Integrations
      module Aire
        # Server-to-server reads for the AIRE worker app. AIRE signs in the worker
        # and proxies these requests with its source credential; Payroll resolves
        # the worker only through that source's saved employee mapping.
        class WorkerStatementsController < ActionController::API
          include ConnectedPayrollControl
          before_action :require_connected_payroll!
          before_action :authenticate_source!
          include CompanyRlsScoped
          before_action :set_employee!
          before_action :set_statement_item!, only: %i[show pdf]
          around_action :with_worker_actor

          UUID_FORMAT = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

          def index
            items = pay_statements.list
            record_access!("worker_statements#listed", record_type: "Employee", record_id: @employee.id, count: items.size)
            render json: { worker: worker_json, statements: items.map { |item| EmployeePayStatements::Presenter.new(item).summary } }
          end

          def show
            payload = EmployeePayStatements::Presenter.new(@item).detail
            record_access!("worker_statement#viewed", record_type: "PayrollItem", record_id: @item.id)
            render json: payload
          end

          def pdf
            unless EarningsStatementEligibility.printable?(@item)
              return render json: { error: "This payroll record does not have a current earnings statement" }, status: :unprocessable_entity
            end

            generator = PayStubGenerator.new(@item)
            pdf_data = generator.generate
            record_access!("worker_statement#pdf_downloaded", record_type: "PayrollItem", record_id: @item.id)
            send_data pdf_data, filename: generator.filename, type: "application/pdf", disposition: "inline"
          end

          private

          # The events endpoint finds its source through the calendar period in
          # the payload. A read has no payload, so compare the credential with
          # every active AIRE source in constant time and require one match.
          def rls_company_id
            @source&.company_id
          end

          def authenticate_source!
            TenantScope.as_system(reason: "Authenticate AIRE source credential") { match_source! }
          end

          def match_source!
            secret = (request.headers["X-Shared-Secret"].presence || request.headers["X-Payroll-Shared-Secret"]).to_s
            matches = TimeTrackingSource.active.where(source_type: "aire_services").select do |source|
              expected = source.shared_secret.to_s
              expected.present? && secret.present? && expected.bytesize == secret.bytesize &&
                ActiveSupport::SecurityUtils.secure_compare(expected, secret)
            end
            return @source = matches.first if matches.one?

            Rails.logger.warn("AIRE worker statement credential matched #{matches.size} active sources") if matches.many?
            render json: { error: "Invalid AIRE integration credentials" }, status: :unauthorized
          end

          def set_employee!
            mapping = TimeTrackingEmployeeMapping.find_by(
              time_tracking_source_id: @source.id, company_id: @source.company_id, source_user_uuid: source_user_uuid
            ) if source_user_uuid
            @employee = Employee.find_by(id: mapping.employee_id, company_id: @source.company_id) if mapping
            not_found unless @employee
          end

          def with_worker_actor(&action)
            Current.with_isolated_actor(AuditActor.source_worker(id: source_user_uuid), &action)
          end

          def set_statement_item!
            @item = pay_statements.find(params[:id])
            not_found unless @item
          end

          def pay_statements
            @pay_statements ||= EmployeePayStatements.new(company: @source.company, employee: @employee)
          end

          def source_user_uuid
            value = params[:source_user_uuid].to_s.downcase
            value if UUID_FORMAT.match?(value)
          end

          def worker_json
            {
              employment_type: @employee.employment_type,
              contractor: @employee.contractor?,
              display_name: [ @employee.first_name, @employee.last_name ].compact_blank.join(" ")
            }
          end

          def record_access!(action, record_type:, record_id:, count: nil)
            AuditLog.record!(
              actor: Current.actor,
              company_id: @source.company_id,
              action: action,
              record_type: record_type,
              record_id: record_id,
              subject_name: @employee.full_name,
              metadata: {
                employee_id: @employee.id,
                payroll_item_id: (@item&.id),
                time_tracking_source_id: @source.id,
                source_user_uuid: source_user_uuid,
                statement_count: count
              }.compact,
              ip_address: request.remote_ip,
              user_agent: request.user_agent,
              request_id: request.request_id,
              event_category: "integration"
            )
          end

          def not_found
            render json: { error: "Not found" }, status: :not_found
          end
        end
      end
    end
  end
end
