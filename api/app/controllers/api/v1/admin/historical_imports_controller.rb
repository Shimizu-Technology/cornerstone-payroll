# frozen_string_literal: true

module Api
  module V1
    module Admin
      class HistoricalImportsController < BaseController
        DEFAULT_PER_PAGE = 50
        MAX_PER_PAGE = 200

        before_action :require_historical_payroll_enabled!
        before_action :set_batch, only: %i[show apply lock archive_unlinked_workers update_worker]

        def index
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
          batches = filtered_batches(HistoricalImportBatch.where(company_id: current_company_id))
                    .includes(:applied_by, :locked_by)
                    .recent_first
          total = batches.count
          archive = archive_summary
          page_batches = batches.offset((page - 1) * per_page).limit(per_page).to_a
          mapping_counts = worker_mapping_counts(page_batches)
          render json: {
            data: page_batches.map { |batch| batch_json(batch, mapping_counts: mapping_counts.fetch(batch.id, {})) },
            meta: {
              current_page: page,
              per_page: per_page,
              total_count: total,
              total_pages: (total.to_f / per_page).ceil,
              archive: archive
            }
          }
        end

        def show
          page = [ params.fetch(:page, 1).to_i, 1 ].max
          per_page = params.fetch(:per_page, DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
          scope = filtered_paychecks(@batch.historical_paychecks)
          total = scope.count
          paychecks = scope.includes(:historical_worker, :employee, :historical_pay_period)
                           .reverse_chronological
                           .offset((page - 1) * per_page)
                           .limit(per_page)

          render json: {
            data: batch_json(@batch).merge(
              periods: @batch.historical_pay_periods.reverse_chronological
                             .limit(QuickbooksHistory::BundleParser::MAX_PERIOD_COUNT)
                             .map { |period| period_json(period) },
              workers: @batch.historical_workers.includes(:employee).order(:normalized_name)
                             .limit(QuickbooksHistory::BundleParser::MAX_WORKER_COUNT)
                             .map { |worker| worker_json(worker) },
              paychecks: paychecks.map { |paycheck| paycheck_json(paycheck) }
            ),
            meta: {
              current_page: page,
              per_page: per_page,
              total_count: total,
              total_pages: (total.to_f / per_page).ceil
            }
          }
        end

        def preview
          files = Array(params[:files]).compact
          result = QuickbooksHistory::ImportService.new(
            company: current_company,
            files: files,
            actor: current_user
          ).call
          unless result.success?
            render json: error_payload(result.error), status: :unprocessable_entity
            return
          end

          render json: { data: batch_json(result.batch), meta: { idempotent: result.idempotent } }
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: error_payload(e), status: :unprocessable_entity
        end

        def apply
          batch = QuickbooksHistory::LifecycleService.new(batch: @batch, actor: current_user).apply!(
            acknowledgement: params[:acknowledgement]
          )
          render json: { data: batch_json(batch) }
        rescue ArgumentError => e
          render json: error_payload(e), status: :unprocessable_entity
        end

        def lock
          batch = QuickbooksHistory::LifecycleService.new(batch: @batch, actor: current_user).lock!
          render json: { data: batch_json(batch) }
        rescue ArgumentError => e
          render json: error_payload(e), status: :unprocessable_entity
        end

        def archive_unlinked_workers
          result = QuickbooksHistory::BulkArchiveOnlyService.new(batch: @batch, actor: current_user).call
          unless result.success?
            render json: error_payload(result.error), status: :unprocessable_entity
            return
          end

          render json: {
            data: batch_json(@batch.reload),
            meta: { reviewed_count: result.reviewed_count }
          }
        end

        def update_worker
          worker = @batch.historical_workers.find(params[:worker_id])
          archive_only = ActiveModel::Type::Boolean.new.cast(params[:archive_only])
          if params[:employee_id].present?
            employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
            raise ArgumentError, "The selected live employee could not be found for this client" unless employee
          end
          QuickbooksHistory::MappingService.new(
            worker: worker,
            employee: employee,
            actor: current_user,
            archive_only: archive_only
          ).call
          render json: { data: worker_json(worker.reload) }
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: error_payload(e), status: :unprocessable_entity
        end

        private

        def require_historical_payroll_enabled!
          return if current_company&.historical_payroll_enabled?

          render json: {
            error: "Historical payroll is not enabled for this client",
            details: {}
          }, status: :forbidden
        end

        def set_batch
          @batch = HistoricalImportBatch.where(company_id: current_company_id).find(params[:id])
        end

        def filtered_paychecks(scope)
          scope = scope.where(historical_pay_period_id: params[:period_id]) if params[:period_id].present?
          scope = scope.where(pay_date: Date.new(params[:year].to_i, 1, 1)..Date.new(params[:year].to_i, 12, 31)) if params[:year].present?
          if params[:search].present?
            query = "%#{HistoricalPaycheck.sanitize_sql_like(params[:search].to_s.strip)}%"
            scope = scope.where("source_employee_name ILIKE ? OR check_number ILIKE ?", query, query)
          end
          scope
        rescue Date::Error
          scope.none
        end

        def filtered_batches(scope)
          if params[:search].present?
            query = "%#{HistoricalImportBatch.sanitize_sql_like(params[:search].to_s.strip)}%"
            scope = scope.where("historical_import_batches.source_label ILIKE ? OR historical_import_batches.bundle_digest ILIKE ?", query, query)
          end
          scope = scope.where(status: params[:status]) if params[:status].present?
          if params[:department_id].present?
            scope = scope.joins(historical_workers: :employee)
                         .where(employees: { department_id: params[:department_id] })
                         .distinct
          end
          scope
        end

        def error_payload(error)
          details = error.respond_to?(:record) ? error.record.errors.to_hash : {}
          { error: error.message, details: details }
        end

        def archive_summary
          visible_batches = HistoricalImportBatch.where(company_id: current_company_id).visible_history
          paychecks = HistoricalPaycheck.where(historical_import_batch_id: visible_batches.select(:id))
          {
            applied_batch_count: visible_batches.count,
            paycheck_count: paychecks.count,
            worker_count: HistoricalWorker.where(historical_import_batch_id: visible_batches.select(:id)).distinct.count(:normalized_name),
            first_pay_date: paychecks.minimum(:pay_date),
            last_pay_date: paychecks.maximum(:pay_date),
            gross_pay: paychecks.sum(:gross_pay).to_s,
            net_pay: paychecks.sum(:net_pay).to_s
          }
        end

        def batch_json(batch, mapping_counts: nil)
          mapping_counts ||= batch.historical_workers.group(:mapping_status).count
          {
            id: batch.id,
            company_id: batch.company_id,
            source_system: batch.source_system,
            source_label: batch.source_label,
            bundle_digest: batch.bundle_digest,
            importer_version: batch.importer_version,
            status: batch.status,
            source_file_manifest: batch.source_file_manifest,
            preview_summary: batch.preview_summary,
            reconciliation_summary: batch.reconciliation_summary,
            warnings: batch.warnings,
            errors: batch.validation_errors,
            worker_review_summary: {
              total: mapping_counts.values.sum,
              needs_review: mapping_counts.fetch("needs_review", 0),
              linked: mapping_counts.fetch("exact_match", 0) + mapping_counts.fetch("manual_match", 0),
              archive_only: mapping_counts.fetch("archive_only", 0)
            },
            applied_at: batch.applied_at,
            applied_by_name: batch.applied_by&.name,
            locked_at: batch.locked_at,
            locked_by_name: batch.locked_by&.name,
            created_at: batch.created_at
          }
        end

        def worker_mapping_counts(batches)
          counts = HistoricalWorker.where(historical_import_batch_id: batches.map(&:id))
                                   .group(:historical_import_batch_id, :mapping_status)
                                   .count
          counts.each_with_object(Hash.new { |hash, key| hash[key] = {} }) do |((batch_id, status), count), grouped|
            grouped[batch_id][status] = count
          end
        end

        def period_json(period)
          {
            id: period.id,
            period_type: period.period_type,
            start_date: period.start_date,
            end_date: period.end_date,
            pay_date: period.pay_date,
            source_label: period.source_label,
            paycheck_count: period.paycheck_count,
            totals: period.totals
          }
        end

        def worker_json(worker)
          {
            id: worker.id,
            source_name: worker.source_name,
            source_status: worker.source_status,
            hire_date: worker.hire_date,
            employee_id: worker.employee_id,
            employee_name: worker.employee&.full_name,
            mapping_status: worker.mapping_status,
            match_method: worker.match_method,
            match_confidence: worker.match_confidence&.to_f
          }
        end

        def paycheck_json(paycheck)
          {
            id: paycheck.id,
            historical_pay_period_id: paycheck.historical_pay_period_id,
            historical_worker_id: paycheck.historical_worker_id,
            employee_id: paycheck.employee_id,
            employee_name: paycheck.employee&.full_name,
            source_employee_name: paycheck.source_employee_name,
            pay_date: paycheck.pay_date,
            period_start: paycheck.period_start,
            period_end: paycheck.period_end,
            period_type: paycheck.historical_pay_period.period_type,
            payment_method: paycheck.payment_method,
            check_number: paycheck.check_number,
            source_status: paycheck.source_status,
            reconciliation_status: paycheck.reconciliation_status,
            hours_total: paycheck.hours_total.to_s,
            gross_pay: paycheck.gross_pay.to_s,
            adjusted_gross: paycheck.adjusted_gross.to_s,
            pretax_deductions: paycheck.pretax_deductions.to_s,
            employee_taxes: paycheck.employee_taxes.to_s,
            federal_income_tax: paycheck.federal_income_tax.to_s,
            social_security_tax: paycheck.social_security_tax.to_s,
            medicare_tax: paycheck.medicare_tax.to_s,
            after_tax_deductions: paycheck.after_tax_deductions.to_s,
            net_pay: paycheck.net_pay.to_s,
            employer_taxes: paycheck.employer_taxes.to_s,
            employer_contributions: paycheck.employer_contributions.to_s,
            total_payroll_cost: paycheck.total_payroll_cost.to_s,
            hours_breakdown: paycheck.hours_breakdown,
            earnings_breakdown: paycheck.earnings_breakdown,
            pretax_deduction_breakdown: paycheck.pretax_deduction_breakdown,
            after_tax_deduction_breakdown: paycheck.after_tax_deduction_breakdown,
            employee_tax_breakdown: paycheck.employee_tax_breakdown,
            employer_tax_breakdown: paycheck.employer_tax_breakdown,
            employer_contribution_breakdown: paycheck.employer_contribution_breakdown
          }
        end
      end
    end
  end
end
