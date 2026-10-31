# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PriorProviderHistoriesController < BaseController
        rescue_from ArgumentError, ActiveRecord::RecordInvalid, QuickbooksHistory::SourceFileStorageService::StorageError do |error|
          render json: { error: error.message }, status: :unprocessable_entity
        end
        rescue_from QuickbooksHistory::ClientBootstrapAuthorization::NotAuthorized do |error|
          render json: { error: error.message }, status: :forbidden
        end

        def index
          candidates = current_company.pay_periods.calculated.where(cycle: "regular", run_purpose: "regular", parallel_run: false, correction_status: nil)
            .where("pay_date < ?", Date.current).order(:pay_date, :id).limit(PriorProviderHistory::SourceAdapter::MAX_RUNS).map do |period|
              PriorProviderHistory::SourceAdapter.candidate(period)
            end
          render json: {
            company_id: current_company_id,
            enabled: current_company.historical_payroll_enabled?,
            can_manage: StaffRolePolicy.allowed?(current_user, :manage_client_configuration, company: current_company) && !current_company.test_workspace?,
            candidates: candidates,
            employees: current_company.employees.order(:last_name, :first_name).map { |employee| { id: employee.id, name: employee.full_name } },
            onboardings: PriorProviderHistoryOnboarding.where(company_id: current_company_id).order(id: :desc).map { |record| serialize(record) }
          }
        end

        def preview
          plan = PriorProviderHistory::Plan.new(company: current_company, payload: payload).call
          render json: { ready: plan.ready?, errors: plan.errors, digest: plan.digest, totals: plan.ready? ? plan.totals : nil }
        end

        def create
          record = PriorProviderHistory::Conversion.new(company: current_company, actor: current_user, payload: payload,
            preview_digest: params.require(:preview_digest), idempotency_key: params.require(:idempotency_key),
            files: params[:files], acknowledgement: params[:acknowledgement]).call
          render json: { onboarding: serialize(record) }, status: :created
        end

        def activate
          record = scoped_record
          PriorProviderHistory::Activation.new(onboarding: record, actor: current_user, acknowledgement: params[:acknowledgement]).call
          render json: { onboarding: serialize(record.reload) }
        end

        def reverse
          record = scoped_record
          PriorProviderHistory::Reversal.new(onboarding: record, actor: current_user, reason: params[:reason], acknowledgement: params[:acknowledgement]).call
          render json: { onboarding: serialize(record.reload) }
        end

        def source_file
          record = scoped_record
          batch = record.historical_import_batch
          file = batch.historical_import_source_files.find(params[:source_file_id])
          bytes = QuickbooksHistory::SourceFileVerificationService.new(batch: batch, actor: current_user).verified_bytes!(file)
          send_data bytes, filename: file.original_filename, type: file.content_type, disposition: "attachment"
        rescue R2StorageService::DownloadError => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        private

        def payload
          raw = params.require(:payload)
          value = raw.is_a?(String) ? JSON.parse(raw) : (raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw)
          raise ArgumentError, "History payload must be an object" unless value.is_a?(Hash)
          value
        rescue JSON::ParserError
          raise ArgumentError, "History payload is not valid JSON"
        end

        def scoped_record
          PriorProviderHistoryOnboarding.where(company_id: current_company_id).find(params[:id])
        end

        def serialize(record)
          batch = record.historical_import_batch
          {
            id: record.id, status: record.status, provider_name: batch.source_label, tax_year: record.tax_year,
            takeover_on: record.takeover_on.iso8601, converted_at: record.created_at.iso8601,
            activated_at: record.activated_at&.iso8601, reversed_at: record.reversed_at&.iso8601,
            reversal_reason: record.reversal_reason, batch_id: batch.id,
            periods: batch.historical_pay_periods.chronological.map { |period| period.attributes.slice("id", "pay_date", "start_date", "end_date", "paycheck_count", "totals") },
            totals: batch.preview_summary["totals"],
            employee_balances: batch.historical_ytd_bridge&.historical_employee_ytd_balances&.map { |balance| balance.attributes.slice("employee_id", "gross_pay", "net_pay", "federal_income_tax", "social_security_taxable_wages", "social_security_taxable_tips", "medicare_taxable_wages") } || [],
            source_files: batch.historical_import_source_files.in_manifest_order.map { |file| file.attributes.slice("id", "original_filename", "sha256", "byte_size", "verification_status") },
            source_run_ids: record.evidence["source_run_ids"],
            filing_responsibilities: record.status == "active" ? record.filing_after.map { |row| row.slice("filing_type", "quarter", "responsible_party", "imported_payroll_inclusion") } : [],
            can_reverse: record.status != "reversed" && !current_company.pay_periods.committed.exists?
          }
        end
      end
    end
  end
end
