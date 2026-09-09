# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollFilingResponsibilitiesController < BaseController
        def index
          tax_year = parse_tax_year!
          quarter = parse_optional_quarter!
          filing_type = params[:filing_type].presence

          data = if filing_type
            PayrollFilingResponsibilityGate.new(
              company: current_company,
              tax_year: tax_year,
              quarter: quarter,
              filing_type: filing_type
            ).payload
          elsif quarter
            PayrollFilingResponsibilityGate.quarterly(
              company: current_company,
              tax_year: tax_year,
              quarter: quarter
            )
          else
            PayrollFilingResponsibilityGate.annual(company: current_company, tax_year: tax_year)
          end

          render json: { data: data, permissions: permissions_payload }
        rescue ArgumentError => e
          render json: { error: e.message, details: {} }, status: :unprocessable_entity
        end

        def upsert
          input = responsibility_params
          tax_year = parse_tax_year!(input[:tax_year])
          quarter = parse_optional_quarter!(input[:quarter])
          filing_types = normalized_filing_types(input, quarter: quarter)
          source_cutoff_date = parse_optional_date!(input[:source_cutoff_date])

          records = PayrollFilingResponsibilityRecorder.new(
            company: current_company,
            actor: current_user,
            tax_year: tax_year,
            quarter: quarter,
            filing_types: filing_types,
            responsible_party: input[:responsible_party],
            imported_payroll_inclusion: input[:imported_payroll_inclusion],
            source_cutoff_date: source_cutoff_date,
            notes: input[:notes]
          ).call

          gate = if quarter
            PayrollFilingResponsibilityGate.quarterly(
              company: current_company,
              tax_year: tax_year,
              quarter: quarter
            )
          else
            PayrollFilingResponsibilityGate.annual(company: current_company, tax_year: tax_year)
          end

          render json: {
            data: records.map(&:decision_payload),
            filing_gate: gate,
            permissions: permissions_payload
          }
        rescue ActionController::ParameterMissing, ArgumentError, ActiveRecord::RecordInvalid => e
          details = e.respond_to?(:record) ? e.record.errors.to_hash : {}
          render json: { error: e.message, details: details }, status: :unprocessable_entity
        rescue PayrollFilingResponsibilityPolicy::NotAuthorized => e
          render json: { error: e.message, details: {} }, status: :forbidden
        end

        private

        def responsibility_params
          params.require(:responsibility).permit(
            :tax_year,
            :quarter,
            :filing_type,
            :responsible_party,
            :imported_payroll_inclusion,
            :source_cutoff_date,
            :notes,
            filing_types: []
          )
        end

        def parse_tax_year!(value = params[:tax_year])
          year = Integer(value, exception: false)
          unless year && year >= 2000 && year <= Date.current.year + 1
            raise ArgumentError, "tax_year must be a valid 4-digit tax year"
          end

          year
        end

        def parse_optional_quarter!(value = params[:quarter])
          return if value.blank?

          quarter = Integer(value, exception: false)
          raise ArgumentError, "quarter must be 1, 2, 3, or 4" unless quarter.in?(1..4)

          quarter
        end

        def parse_optional_date!(value)
          return if value.blank?

          Date.iso8601(value.to_s)
        rescue Date::Error
          raise ArgumentError, "source_cutoff_date must use YYYY-MM-DD"
        end

        def normalized_filing_types(input, quarter:)
          values = Array(input[:filing_types]).presence || Array(input[:filing_type]).presence
          values || (quarter ? PayrollFilingResponsibility::QUARTERLY_FILING_TYPES : PayrollFilingResponsibility::ANNUAL_FILING_TYPES)
        end

        def permissions_payload
          {
            can_view: StaffRolePolicy.allowed?(current_user, :payroll_operations),
            can_record: StaffRolePolicy.allowed?(current_user, :manage_filing_review)
          }
        end
      end
    end
  end
end
