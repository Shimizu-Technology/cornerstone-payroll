# frozen_string_literal: true

module Api
  module V1
    module Admin
      class YearEndController < BaseController
        # GET /api/v1/admin/year_end/clients?year=2026
        # Every accessible live client with its year-end status, worst first.
        def clients
          year = parse_year!
          render json: { data: YearEnd::ClientsOverview.new(user: current_user, year: year).call }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # GET /api/v1/admin/year_end/checklist?year=2026
        # The current client's ordered year-end checklist.
        def checklist
          year = parse_year!
          render json: { data: YearEnd::Checklist.new(company: current_company, year: year, user: current_user).call }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        # POST /api/v1/admin/year_end/acknowledgements
        # Records an audited "reviewed" decision on one judgment warning.
        def create_acknowledgement
          input = params.require(:acknowledgement).permit(:tax_year, :warning_code, :warning_digest, :note)
          year = parse_year!(input[:tax_year])
          record = YearEnd::AcknowledgementRecorder.new(
            company: current_company,
            actor: current_user,
            tax_year: year,
            warning_code: input[:warning_code],
            warning_digest: input[:warning_digest],
            note: input[:note]
          ).call
          render json: { data: record.payload }, status: :created
        rescue ActionController::ParameterMissing, ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue YearEnd::AcknowledgementRecorder::StaleWarning => e
          render json: { error: e.message }, status: :conflict
        rescue PayrollFilingResponsibilityPolicy::NotAuthorized => e
          render json: { error: e.message }, status: :forbidden
        end

        # POST /api/v1/admin/year_end/one_off_payees/link
        # Links a one-off 1099 payee's checks to an existing contractor, so
        # they count toward that contractor's single 1099.
        def link_one_off_payee
          input = params.require(:payee).permit(:tax_year, :code, :digest, :employee_id)
          resolve_payee(input) do |resolver|
            resolver.link!(payee_code: input[:code], payee_digest: input[:digest], employee_id: input[:employee_id])
          end
        end

        # POST /api/v1/admin/year_end/one_off_payees/contractor
        # Adds a contractor record from the payee's W-9 and links the checks.
        def create_one_off_payee_contractor
          input = params.require(:payee).permit(:tax_year, :code, :digest, contractor: YearEnd::OneOffPayeeResolver::CONTRACTOR_FIELDS)
          resolve_payee(input) do |resolver|
            resolver.create_contractor!(payee_code: input[:code], payee_digest: input[:digest], attributes: input[:contractor] || {})
          end
        end

        # POST /api/v1/admin/year_end/one_off_payees/unlink
        # Undoes a link; the checks become a one-off payee again. employee_id
        # is the contractor the reviewer saw the checks linked to.
        def unlink_one_off_payee
          input = params.require(:payee).permit(:tax_year, :employee_id, check_ids: [])
          resolve_payee(input) { |resolver| resolver.unlink!(check_ids: input[:check_ids], employee_id: input[:employee_id]) }
        end

        # POST /api/v1/admin/year_end/form_1099_mark_ready
        # Records the "1099s ready" sign-off on the inputs the reviewer saw.
        def form_1099_mark_ready
          input = params.require(:form_1099).permit(:tax_year, :inputs_fingerprint, :notes)
          year = parse_year!(input[:tax_year])
          company = current_company
          readiness = company.with_lock do
            revalidate_current_company_write_access!(company: company, capability: :manage_client_administration)
            YearEnd::Form1099MarkReady.new(
              company: company, actor: current_user, tax_year: year,
              inputs_fingerprint: input[:inputs_fingerprint], notes: input[:notes]
            ).call
          end
          render json: { data: readiness.payload(fingerprint: readiness.ready_fingerprint) }
        rescue ActionController::ParameterMissing, ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue YearEnd::Form1099MarkReady::Refused => e
          render json: { error: e.message, **e.details }, status: e.status
        end

        private

        def rls_system_reason
          "Year-end overview spans authorized companies" if action_name == "clients"
        end

        # Runs one payee resolution and answers with what changed. The
        # resolver takes the company lock and rechecks access under it.
        def resolve_payee(input)
          year = parse_year!(input[:tax_year])
          result = yield YearEnd::OneOffPayeeResolver.new(company: current_company, actor: current_user, tax_year: year)
          employee = result[:employee]
          render json: {
            data: {
              employee: employee && { id: employee.id, name: employee.full_name, created: employee.previously_new_record? },
              check_ids: result[:checks].map(&:id)
            }
          }, status: employee&.previously_new_record? ? :created : :ok
        rescue ActionController::ParameterMissing, ArgumentError, YearEnd::OneOffPayeeResolver::Refused => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence.presence || e.message, errors: e.record.errors.to_hash(true) }, status: :unprocessable_entity
        rescue YearEnd::OneOffPayeeResolver::StalePayee => e
          render json: { error: e.message }, status: :conflict
        rescue PayrollFilingResponsibilityPolicy::NotAuthorized => e
          render json: { error: e.message }, status: :forbidden
        end

        def parse_year!(value = params[:year])
          year = Integer(value, exception: false)
          unless year && year >= YearEnd::Checklist::FIRST_TAX_YEAR && year <= Date.current.year + 1
            raise ArgumentError, "Choose a tax year from #{YearEnd::Checklist::FIRST_TAX_YEAR} to #{Date.current.year + 1}"
          end

          year
        end
      end
    end
  end
end
