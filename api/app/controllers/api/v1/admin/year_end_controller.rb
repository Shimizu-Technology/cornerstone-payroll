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

        private

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
