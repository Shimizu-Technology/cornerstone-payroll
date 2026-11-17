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
            add_back = nil
            if exclusion
              unless Employee.where(company: current_company).eligible_for_payroll_run(period, explicitly_selected: true).exists?(id: employee.id)
                return render json: { error: "This employee is not eligible for this run's dates. Review their employment status before adding them back." }, status: :unprocessable_entity
              end

              reason = exclusion.reason
              exclusion.destroy!
              # Staff are adding them back to pay them. An earlier "Not paid
              # this period" or "None this period" answer for them no longer
              # holds, so the run waits for their hours again.
              cleared_resolutions = PayrollEntryResolution.where(pay_period: period, employee: employee).map do |resolution|
                { payroll_standing_change_id: resolution.payroll_standing_change_id, note: resolution.note }.tap { resolution.destroy! }
              end
              # Hours stay out; staff enter them next. The import's other
              # amounts come back so the check isn't short a deduction.
              add_back = PayrollImport::AddBackRestore.new(pay_period: period, employee: employee, actor: current_user).call
              if add_back&.dig(:restored)&.any?
                period.invalidate_calculation!(reason: "An employee was added back with amounts restored from the import.")
              end
              AuditLog.record!(user: current_user, company_id: current_company.id,
                action: "pay_period_excluded_employees#destroy", record_type: "PayPeriod", record_id: period.id,
                subject_name: employee.full_name, metadata: { employee_id: employee.id, original_exclusion_reason: reason,
                  import_id: add_back&.dig(:import_id), restored_import_amounts: add_back&.dig(:restored),
                  not_restored_import_amounts: add_back&.dig(:not_restored),
                  cleared_entry_resolutions: cleared_resolutions.presence }.compact)
            end
            skip_default_audit_log!
            # A repeat after a lost response gets the add-back already recorded.
            add_back ||= PayrollImport::AddBackRestore.recent(period)[employee.id] unless exclusion
            render json: { expected_entries: PayrollExpectedEntries.new(period).payload,
              add_back: add_back || { employee_id: employee.id, employee_name: employee.full_name, restored: [], not_restored: [] } }
          end
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Pay run or employee not found" }, status: :not_found
        end
      end
    end
  end
end
