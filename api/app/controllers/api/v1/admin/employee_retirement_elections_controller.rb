# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeRetirementElectionsController < BaseController
        before_action :set_employee

        def index
          elections = @employee.employee_retirement_elections.includes(:created_by).recent_first
          render json: { data: elections.map { |election| serialize(election) } }
        end

        def create
          election = EmployeeRetirementElectionChangeService.new(
            employee: @employee,
            attributes: election_params,
            actor: current_user,
            source: "staff",
            reason: election_params[:reason]
          ).call!
          render json: { data: serialize(election) }, status: :created
        rescue EmployeeRetirementElectionChangeService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          return if @employee

          render json: { error: "Employee not found" }, status: :not_found
        end

        def election_params
          params.require(:retirement_election).permit(
            :effective_on, :plan_name, :eligible, :participating,
            :traditional_contribution_type, :traditional_rate, :traditional_amount,
            :roth_contribution_type, :roth_rate, :roth_amount, :eligible_compensation,
            :catch_up_enabled, :limit_priority, :plan_annual_employee_limit,
            :employer_match_mode, :employer_match_rate, :employer_match_deferral_cap_rate,
            :employer_match_period_cap, :employer_match_annual_cap,
            :employer_match_ytd_before_system, :employer_match_destination,
            :true_up_policy, :reason
          )
        end

        def serialize(election)
          election.as_json(except: [ :created_by_id ]).merge("created_by_name" => election.created_by&.name)
        end
      end
    end
  end
end
