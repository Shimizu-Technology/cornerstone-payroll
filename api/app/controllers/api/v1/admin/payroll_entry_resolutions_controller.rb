# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollEntryResolutionsController < BaseController
        def create
          mutate do |period|
            field = PayrollStandingChange.where(company: current_company).find(params[:payroll_standing_change_id]) if params[:payroll_standing_change_id].present?
            employee = Employee.where(company: current_company).find(field&.employee_id || params[:employee_id])
            row = if field
              PayrollEntryResolution.find_or_initialize_by(pay_period: period, payroll_standing_change: field)
            else
              PayrollEntryResolution.find_or_initialize_by(pay_period: period, employee: employee, payroll_standing_change: nil)
            end
            row.update!(employee: employee, note: params[:note])
          end
        end

        def destroy
          mutate do |period|
            PayrollEntryResolution.where(pay_period: period, employee_id: params[:employee_id],
              payroll_standing_change_id: params[:payroll_standing_change_id].presence).find_each(&:destroy!)
          end
        end

        private

        def mutate
          current_company.with_lock do
            revalidate_current_company_write_access!(capability: :payroll_operations)
            period = PayPeriod.where(company: current_company).lock.find(params[:pay_period_id])
            unless period.draft? || period.calculated?
              return render json: { error: "Only draft or calculated runs can change expected entries" }, status: :unprocessable_entity
            end
            yield period
            render json: { expected_entries: PayrollExpectedEntries.new(period).payload }
          end
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Entry not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end
      end
    end
  end
end
