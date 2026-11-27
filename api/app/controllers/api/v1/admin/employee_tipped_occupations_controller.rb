# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeTippedOccupationsController < BaseController
        class InvalidInput < StandardError; end

        CODES = CompanyJobRole::CODES
        FIELDS = %w[id occupation_code effective_from effective_to].freeze

        before_action :set_employee, only: %i[index create update destroy]

        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "Employee or occupation code not found." }, status: :not_found
        end
        rescue_from ActionController::ParameterMissing do |error|
          render json: { error: "#{error.param.to_s.humanize} is required." }, status: :bad_request
        end
        rescue_from InvalidInput do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end
        rescue_from ActiveRecord::RecordInvalid do |error|
          render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end

        def catalog
          render json: { codes: CODES }
        end

        def index
          render json: history
        end

        def create
          code = validated_code
          start_date = parse_date(params.require(:effective_from))
          write do
            occupations = @employee.employee_tipped_occupations
            previous = occupations.find(params[:replace_id]) if params[:replace_id].present?
            end_date = date_or_nil(params[:effective_to])
            if previous
              unless start_date > previous.effective_from && (previous.effective_to.nil? || start_date <= previous.effective_to)
                raise InvalidInput, "The new start date must fall after the old start date and within the old effective period."
              end
              end_date = previous.effective_to unless params.key?(:effective_to)
            end

            save_occupation(@employee, code, start_date, end_date, previous: previous)
          end
          render json: history, status: :created
        end

        def update
          end_date = parse_date(params.require(:effective_to))
          write do
            occupation = @employee.employee_tipped_occupations.find(params[:id])
            if occupation.effective_to && end_date > occupation.effective_to
              raise InvalidInput, "An end date cannot extend the existing effective period."
            end

            before = occupation.slice(*FIELDS)
            occupation.update!(effective_to: end_date)
            audit_change("end", occupation, before: before) if occupation.saved_change_to_effective_to?
          end
          render json: history
        end

        def destroy
          write do
            occupation = @employee.employee_tipped_occupations.find(params[:id])
            years = occupation.effective_from.year..occupation.effective_to&.year
            filed_year = PayrollFilingRecord.where(company_id: current_company.id, filing_type: "w2_gu_w3_ss", tax_year: years).minimum(:tax_year)
            if filed_year
              raise InvalidInput, "This entry overlaps a W-2 filing for #{filed_year}. Use End or Change to preserve its history."
            end

            occupation.destroy!
            audit_change("remove", occupation)
          end
          render json: history
        end

        def bulk_set
          use_role_code = params[:use_role_code] == true
          code = validated_code unless use_role_code
          year = Integer(params.require(:tax_year).to_s, 10, exception: false)
          unless year && year >= 2026 && (W2GuAggregator::SS_WAGE_BASE_BY_YEAR.key?(year) || AnnualTaxConfig.for_year(year)&.ss_wage_base)
            raise InvalidInput, "Choose a supported tax year."
          end

          period = Date.new(year, 1, 1)..Date.new(year, 12, 31)
          start_date = date_or_nil(params[:effective_from]) || period.begin
          raise InvalidInput, "Choose a start date in the selected tax year." unless period.cover?(start_date)

          ids = params.permit(employee_ids: []).fetch(:employee_ids, []).map { |id| Integer(id.to_s, 10, exception: false) }.uniq
          raise InvalidInput, "Select at least one employee." if ids.empty? || ids.any?(&:nil?)

          expected = params[:expected_role_codes]
          expected = expected.permit(*ids.map(&:to_s)).to_h if expected.is_a?(ActionController::Parameters)
          overrides = params[:overrides]
          overrides = overrides.is_a?(ActionController::Parameters) ? overrides.permit(*ids.map(&:to_s)).to_h : {}
          capped_count = 0
          write do
            report = W2GuAggregator.new(current_company, year).generate
            eligible_ids = report[:employees].filter_map do |row|
              row[:employee_id] if row[:reported_tips_total].to_d.positive? && row[:box14b_tipped_occupation_codes].blank?
            end
            unless (ids - eligible_ids).empty?
              raise InvalidInput, "The warning list has changed. Refresh the checklist and select the employees again."
            end

            next_starts = EmployeeTippedOccupation.where(company_id: current_company.id, employee_id: ids)
              .where("effective_from > ?", start_date).group(:employee_id).minimum(:effective_from)
            employees = current_company.employees.where(id: ids).includes(:company_job_role).order(:id).lock.to_a
            selected_codes = use_role_code ? role_codes!(employees, overrides, expected) : {}
            employees.each do |employee|
              selected_code = selected_codes.fetch(employee.id, code)
              next_start = next_starts[employee.id]
              capped_count += 1 if next_start
              save_occupation(employee, selected_code, start_date, next_start&.prev_day)
            end
          end

          render json: { count: ids.length, capped_count: capped_count }, status: :created
        rescue ReportValidationError, W2GuAggregator::MissingWageBase => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        private

        def role_codes!(employees, overrides, expected)
          invalid = []
          changed = []
          codes = employees.to_h do |employee|
            key = employee.id.to_s
            override = overrides[key].presence
            code = override || employee.company_job_role&.occupation_code
            invalid << employee.full_name unless CODES.key?(code)
            if !override && expected.respond_to?(:key?) && expected.key?(key) && expected[key] != code
              changed << employee.full_name
            end
            [ employee.id, code ]
          end
          if invalid.any?
            raise InvalidInput, "Choose an occupation code override for #{invalid.to_sentence}."
          end
          if changed.any?
            raise InvalidInput, "Role codes changed for #{changed.to_sentence}. Refresh the checklist and try again."
          end

          codes
        end

        def write
          current_company.with_lock(requires_new: true) do
            revalidate_current_company_write_access!
            @employee&.lock!
            yield
          end
        end

        def set_employee
          @employee = current_company.employees.find(params[:employee_id])
        end

        def history
          { data: @employee.employee_tipped_occupations.order(effective_from: :desc, id: :desc).as_json(only: FIELDS), codes: CODES }
        end

        def validated_code
          code = params.require(:occupation_code)
          raise InvalidInput, "Choose a Treasury tipped occupation code." unless CODES.key?(code)

          code
        end

        def date_or_nil(value)
          parse_date(value) if value.present?
        end

        def parse_date(value)
          raise Date::Error unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/) && !value.start_with?("0000")

          Date.iso8601(value)
        rescue Date::Error
          raise InvalidInput, "Enter a valid effective date."
        end

        def save_occupation(employee, code, start_date, end_date, previous: nil)
          occupations = employee.employee_tipped_occupations
          if occupations.where(occupation_code: code).where.not(id: previous&.id).effective_during(start_date..(end_date || Date.new(9999, 12, 31))).exists?
            raise InvalidInput, "The effective period overlaps another entry for this occupation code."
          end

          before = previous&.slice(*FIELDS)
          previous&.update!(effective_to: start_date - 1)
          occupation = occupations.create!(occupation_code: code, effective_from: start_date, effective_to: end_date)
          audit_change(previous ? "change" : "add", occupation, before: before, ended: previous&.slice(*FIELDS))
        end

        def audit_change(action, occupation, **metadata)
          AuditLog.record!(
            user: current_user, company_id: current_company.id, organization_id: current_company.organization_id,
            action: "employee_tipped_occupation##{action}", record_type: "Employee", record_id: occupation.employee_id,
            metadata: metadata.compact.merge(occupation: occupation.slice(*FIELDS))
          )
        end
      end
    end
  end
end
