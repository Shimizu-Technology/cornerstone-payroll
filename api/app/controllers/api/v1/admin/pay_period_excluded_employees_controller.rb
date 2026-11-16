# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayPeriodExcludedEmployeesController < BaseController
        def destroy
          current_company.with_lock do
            revalidate_current_company_write_access!(capability: :payroll_operations)
            period = PayPeriod.where(company: current_company).lock.find(params[:pay_period_id])
            if period.approved?
              return render json: { error: "Unapprove the pay run before adding someone back." }, status: :unprocessable_entity
            end
            unless period.can_edit? && (period.draft? || period.calculated?)
              return render json: { error: "Only draft or calculated pay runs can add someone back." }, status: :unprocessable_entity
            end

            employee = Employee.where(company: current_company).lock.find(params[:employee_id])
            exclusion = period.pay_period_excluded_employees.find_by(employee: employee)
            if exclusion
              unless Employee.where(company: current_company).eligible_for_payroll_run(period, explicitly_selected: true).exists?(id: employee.id)
                return render json: { error: "This employee is not eligible for this run's dates. Review their employment status before adding them back." }, status: :unprocessable_entity
              end

              reason = exclusion.reason
              exclusion.destroy!
              AuditLog.record!(user: current_user, company_id: current_company.id,
                action: "pay_period_excluded_employees#destroy", record_type: "PayPeriod", record_id: period.id,
                subject_name: employee.full_name, metadata: { employee_id: employee.id, original_exclusion_reason: reason })
            end
            skip_default_audit_log!
            render json: { expected_entries: PayrollExpectedEntries.new(period).payload }
          end
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Pay run or employee not found" }, status: :not_found
        end
      end
    end
  end
end
