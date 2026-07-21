# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollLiabilitiesController < BaseController
        audit_actions :evidence

        def index
          pay_period = current_pay_period
          render json: {
            payroll_liability_reconciliation: PayrollLiabilityReconciliationService.new(pay_period: pay_period).call
          }
        end

        def create_payment
          payment = PayrollLiabilitySettlementService.record!(
            pay_period: current_pay_period,
            actor: current_user,
            authority: params[:authority],
            category: params[:category],
            amount: params[:amount],
            payment_date: params[:payment_date],
            payment_method: params[:payment_method],
            confirmation_number: params[:confirmation_number],
            notes: params[:notes],
            idempotency_key: params[:idempotency_key]
          )
          @audit_record = payment
          render_reconciliation(status: :created)
        rescue PayrollLiabilitySettlementService::InvalidStateError, ActiveRecord::RecordInvalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "This payment was already recorded. Refresh to see the latest settlement history." }, status: :conflict
        end

        def reverse_payment
          source = current_pay_period.payroll_liability_payments.find(params[:payment_id])
          payment = PayrollLiabilitySettlementService.reverse!(
            pay_period: current_pay_period,
            actor: current_user,
            source_payment: source,
            reason: params[:reason],
            idempotency_key: params[:idempotency_key]
          )
          @audit_record = payment
          render_reconciliation
        rescue PayrollLiabilitySettlementService::InvalidStateError, ActiveRecord::RecordInvalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Payment not found" }, status: :not_found
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "This reversal was already recorded. Refresh to see the latest settlement history." }, status: :conflict
        end

        def update_due_date
          record = PayrollLiabilityDueDateService.new(
            pay_period: current_pay_period,
            actor: current_user,
            authority: params[:authority],
            category: params[:category],
            due_date: params[:due_date]
          ).call
          @audit_record = record
          render_reconciliation
        rescue ArgumentError, ActiveRecord::RecordInvalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        end

        def create_evidence
          payment = current_pay_period.payroll_liability_payments.find(params[:payment_id])
          raise ArgumentError, "Evidence must be attached to an original payment" if payment.reversal?

          record = PayrollLiabilityEvidenceService.new(payment: payment, actor: current_user).attach!(file: params[:file])
          @audit_record = record
          render_reconciliation(status: :created)
        rescue ArgumentError, ActiveRecord::RecordInvalid => error
          render json: { error: error.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Payment not found" }, status: :not_found
        rescue R2StorageService::UploadError => error
          Rails.logger.error("Liability evidence upload failed: #{error.class}: #{error.message}")
          render json: { error: "Unable to preserve payment evidence" }, status: :service_unavailable
        end

        def evidence
          payment = current_pay_period.payroll_liability_payments.find(params[:payment_id])
          record = payment.evidence.find(params[:evidence_id])
          bytes = PayrollLiabilityEvidenceService.new(payment: payment, actor: current_user).download!(record)
          send_data bytes,
            filename: record.filename,
            type: record.content_type,
            disposition: params[:download] == "true" ? "attachment" : "inline"
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Payment evidence not found" }, status: :not_found
        rescue R2StorageService::DownloadError => error
          Rails.logger.error("Liability evidence download failed: #{error.class}: #{error.message}")
          render json: { error: "Unable to load payment evidence" }, status: :service_unavailable
        end

        private

        def current_pay_period
          @current_pay_period ||= PayPeriod.where(company_id: current_company_id).find(params[:pay_period_id])
        end

        def render_reconciliation(status: :ok)
          render json: {
            payroll_liability_reconciliation: PayrollLiabilityReconciliationService.new(pay_period: current_pay_period).call
          }, status: status
        end

        def audit_record
          @audit_record
        end
      end
    end
  end
end
