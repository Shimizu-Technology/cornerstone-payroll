# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollGoLiveController < BaseController
        def show
          render json: payload(current_company.payroll_go_live_review)
        end

        def preview_setup
          source_company = accessible_source_company!
          batch = current_company.historical_import_batches.find(params.require(:historical_import_batch_id))
          effective_on = hip_parse_date!(params.require(:effective_on))
          review = PayrollGoLiveSetupTransferService.preview!(
            company: current_company,
            source_company: source_company,
            batch: batch,
            effective_on: effective_on,
            actor: current_user
          )
          render json: payload(review.reload)
        rescue ActionController::ParameterMissing, ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def apply_setup
          review = review!
          PayrollGoLiveSetupTransferService.apply!(
            review: review,
            actor: current_user,
            acknowledgement: params[:acknowledgement].to_s
          )
          render json: payload(review.reload)
        rescue ArgumentError, ActiveRecord::RecordInvalid, CompanyPayScheduleChangeService::ChangeError,
               EmployeeW4ElectionChangeService::Error, EmployeeWorkProfileChangeService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def record_parallel_run
          review = review!
          pay_period = current_company.pay_periods.find(params.require(:pay_period_id))
          PayrollParallelRunReviewService.new(
            review: review,
            pay_period: pay_period,
            source_totals: params.require(:source_totals).permit(:employee_count, :gross_pay, :net_pay, :taxes, :deductions),
            notes: params[:notes],
            actor: current_user
          ).call!
          render json: payload(review.reload)
        rescue ActionController::ParameterMissing, ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update_review
          review = review!
          PayrollGoLiveReviewService.new(review: review, actor: current_user).save!(
            attestations: params[:attestations],
            review_notes: params[:review_notes]
          )
          render json: payload(review.reload)
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def sign_technical
          review = review!
          PayrollGoLiveReviewService.new(review: review, actor: current_user)
            .sign_technical!(acknowledgement: params[:acknowledgement])
          render json: payload(review.reload)
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def sign_operations
          review = review!
          PayrollGoLiveReviewService.new(review: review, actor: current_user)
            .sign_operations!(acknowledgement: params[:acknowledgement])
          render json: payload(review.reload)
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def review!
          current_company.payroll_go_live_review || raise(ArgumentError, "Build the setup transfer preview first")
        end

        def accessible_source_company!
          company = Company.find_by(id: params.require(:source_company_id), organization_id: current_company.organization_id)
          unless company && current_user.can_access_company?(company.id)
            raise ArgumentError, "The predecessor client is unavailable"
          end
          company
        end

        def hip_parse_date!(value)
          Date.iso8601(value.to_s)
        rescue Date::Error
          raise ArgumentError, "Enter a valid transfer date"
        end

        def payload(review)
          {
            data: review && review_json(review),
            source_companies: source_companies,
            historical_imports: historical_imports,
            eligible_pay_periods: eligible_pay_periods,
            permissions: {
              can_preview_setup: StaffRolePolicy.allowed?(current_user, :manage_client_configuration),
              can_apply_setup: StaffRolePolicy.allowed?(current_user, :manage_platform),
              can_record_parallel: StaffRolePolicy.allowed?(current_user, :payroll_operations),
              can_sign_technical: StaffRolePolicy.allowed?(current_user, :manage_platform),
              can_sign_operations: current_user.role.in?(%w[org_admin admin manager])
            },
            acknowledgements: {
              apply_setup: PayrollGoLiveSetupTransferService::ACKNOWLEDGEMENT,
              technical: PayrollGoLiveReview::TECHNICAL_ACKNOWLEDGEMENT,
              operations: PayrollGoLiveReview::OPERATIONS_ACKNOWLEDGEMENT
            }
          }
        end

        def source_companies
          Company.where(id: current_user.accessible_company_ids, organization_id: current_company.organization_id)
            .where.not(id: current_company_id).order(:name).map do |company|
              { id: company.id, name: company.name, active: company.active, employee_count: company.employees.active.count }
            end
        end

        def historical_imports
          current_company.historical_import_batches.includes(:historical_client_bootstrap, :historical_ytd_bridge)
            .recent_first.map do |batch|
              {
                id: batch.id,
                source_label: batch.source_label,
                status: batch.status,
                bootstrap_applied: batch.historical_client_bootstrap&.applied? || false,
                ytd_bridge_applied: batch.historical_ytd_bridge&.applied? || false
              }
            end
        end

        def eligible_pay_periods
          current_company.pay_periods.where(status: %w[calculated approved])
            .includes(:payroll_items).order(pay_date: :desc).map do |period|
              {
                id: period.id,
                start_date: period.start_date,
                end_date: period.end_date,
                pay_date: period.pay_date,
                status: period.status,
                parallel_run: period.parallel_run,
                employee_count: period.payroll_items.reject(&:voided?).size,
                gross_pay: period.payroll_items.reject(&:voided?).sum { |item| item.gross_pay.to_d }.round(2),
                net_pay: period.payroll_items.reject(&:voided?).sum { |item| item.net_pay.to_d }.round(2)
              }
            end
        end

        def review_json(review)
          readiness = PayrollGoLiveReadiness.new(review)
          {
            id: review.id,
            status: review.status,
            source_company: { id: review.source_company_id, name: review.source_company.name },
            historical_import_batch_id: review.historical_import_batch_id,
            effective_on: review.effective_on,
            plan_digest: review.plan_digest,
            setup_summary: review.setup_summary,
            setup_plan: review.setup_plan,
            warnings: review.warnings,
            errors: review.validation_errors,
            setup_applied_at: review.setup_applied_at,
            setup_applied_by_name: review.setup_applied_by&.name,
            attestations: review.attestations,
            attestation_labels: PayrollGoLiveReview::ATTESTATIONS,
            review_notes: review.review_notes,
            ready_for_signoff: review.ready_for_signoff?,
            blockers: readiness.blockers,
            readiness: readiness.facts,
            parallel_runs: review.payroll_parallel_run_reviews.includes(:pay_period, :recorded_by)
              .sort_by { |entry| [ entry.pay_period.pay_date, entry.id ] }.reverse.map { |entry| parallel_run_json(entry) },
            technical_signed_at: review.technical_signed_at,
            technical_signed_by_name: review.technical_signed_by&.name,
            operations_signed_at: review.operations_signed_at,
            operations_signed_by_name: review.operations_signed_by&.name,
            approved_at: review.approved_at,
            created_at: review.created_at,
            updated_at: review.updated_at
          }
        end

        def parallel_run_json(entry)
          {
            id: entry.id,
            pay_period_id: entry.pay_period_id,
            period_start: entry.pay_period.start_date,
            period_end: entry.pay_period.end_date,
            pay_date: entry.pay_period.pay_date,
            result: entry.result,
            source_employee_count: entry.source_employee_count,
            cornerstone_employee_count: entry.cornerstone_employee_count,
            source_gross_pay: entry.source_gross_pay,
            source_net_pay: entry.source_net_pay,
            source_taxes: entry.source_taxes,
            source_deductions: entry.source_deductions,
            cornerstone_gross_pay: entry.cornerstone_gross_pay,
            cornerstone_net_pay: entry.cornerstone_net_pay,
            cornerstone_taxes: entry.cornerstone_taxes,
            cornerstone_deductions: entry.cornerstone_deductions,
            differences: entry.differences,
            notes: entry.notes,
            recorded_by_name: entry.recorded_by&.name,
            recorded_at: entry.updated_at
          }
        end
      end
    end
  end
end
