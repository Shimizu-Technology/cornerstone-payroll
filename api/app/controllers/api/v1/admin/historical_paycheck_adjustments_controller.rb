# frozen_string_literal: true

module Api
  module V1
    module Admin
      class HistoricalPaycheckAdjustmentsController < BaseController
        before_action :require_historical_payroll_enabled!
        before_action :set_paycheck, only: %i[index preview create]
        before_action :set_adjustment, only: %i[reverse event]

        def index
          rows = @paycheck.historical_paycheck_adjustments.includes(:created_by, events: :created_by).chronological
          @latest_reportable_pay_date = PayPeriod.reportable_committed.where(company_id: @paycheck.company_id).maximum(:pay_date)
          render json: { data: rows.map { |row| adjustment_json(row) } }
        end

        def preview
          result = HistoricalPayroll::AdjustmentPreviewService.new(
            paycheck: @paycheck, actor: current_user, attributes: adjustment_params
          ).call
          render json: { data: preview_json(result) }
        rescue ArgumentError => e
          render_adjustment_error(e)
        end

        def create
          adjustment = HistoricalPayroll::AdjustmentCreateService.new(
            paycheck: @paycheck,
            actor: current_user,
            attributes: adjustment_params,
            acknowledgement: params[:acknowledgement],
            preview_digest: params[:preview_digest]
          ).call
          render json: { data: adjustment_json(adjustment) }, status: :created
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_adjustment_error(e)
        end

        def reverse
          reversal = HistoricalPayroll::AdjustmentReversalService.new(
            adjustment: @adjustment,
            actor: current_user,
            reason: params[:reason],
            idempotency_key: params[:idempotency_key],
            acknowledgement: params[:acknowledgement]
          ).call
          render json: { data: adjustment_json(reversal) }, status: :created
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_adjustment_error(e)
        end

        def event
          event = HistoricalPayroll::AdjustmentEventService.new(
            adjustment: @adjustment,
            actor: current_user,
            event_type: params[:event_type],
            note: params[:note],
            metadata: params.permit(metadata: {})[:metadata] || {}
          ).call
          render json: { data: event_json(event) }, status: :created
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render_adjustment_error(e)
        end

        private

        def set_paycheck
          @paycheck = HistoricalPaycheck.joins(:historical_import_batch)
                                        .where(company_id: current_company_id)
                                        .where(historical_import_batches: { company_id: current_company_id, status: "locked" })
                                        .find(params[:historical_paycheck_id])
        end

        def set_adjustment
          @adjustment = HistoricalPaycheckAdjustment.where(company_id: current_company_id).find(params[:id])
        end

        def adjustment_params
          params.require(:adjustment).permit(
            :kind, :effective_pay_date, :reason, :external_reference, :idempotency_key,
            :hours_total, *HistoricalPaycheckAdjustment::MONEY_FIELDS,
            evidence_metadata: {},
            hours_breakdown: %i[label amount],
            earnings_breakdown: %i[label amount],
            pretax_deduction_breakdown: %i[label amount],
            after_tax_deduction_breakdown: %i[label amount],
            employee_tax_breakdown: %i[label amount],
            employer_tax_breakdown: %i[label amount],
            employer_contribution_breakdown: %i[label amount]
          ).to_h
        end

        def render_adjustment_error(error)
          if error.is_a?(ActiveRecord::RecordInvalid)
            render json: { error: "Validation failed", details: error.record.errors.messages },
                   status: :unprocessable_entity
          else
            render json: { error: error.message, details: {} }, status: :unprocessable_entity
          end
        end

        def preview_json(result)
          {
            attributes: serialize_attributes(result.attributes),
            errors: result.errors,
            warnings: result.warnings,
            downstream_pay_period_ids: result.downstream_pay_period_ids,
            digest: result.digest,
            ready: result.ready?
          }
        end

        def adjustment_json(adjustment)
          {
            id: adjustment.id,
            historical_paycheck_id: adjustment.historical_paycheck_id,
            reverses_adjustment_id: adjustment.reverses_adjustment_id,
            kind: adjustment.kind,
            effective_pay_date: adjustment.effective_pay_date,
            filing_year: adjustment.filing_year,
            filing_quarter: adjustment.filing_quarter,
            reason: adjustment.reason,
            external_reference: adjustment.external_reference,
            evidence_metadata: adjustment.evidence_metadata,
            idempotency_key: adjustment.idempotency_key,
            created_at: adjustment.created_at,
            created_by_name: adjustment.created_by&.name,
            filing_review_state: adjustment.filing_review_state,
            downstream_impact_required: downstream_impact_required?(adjustment),
            downstream_impact_acknowledged: adjustment.downstream_impact_acknowledged?,
            values: serialize_attributes(
              adjustment.attributes.symbolize_keys.slice(
                *HistoricalPayroll::Ledger::FIELDS,
                *HistoricalPayroll::Ledger::BREAKDOWN_FIELDS
              )
            ),
            events: adjustment.chronological_events.map { |event| event_json(event) }
          }
        end

        def event_json(event)
          {
            id: event.id,
            event_type: event.event_type,
            note: event.note,
            metadata: event.metadata,
            historical_ytd_bridge_id: event.historical_ytd_bridge_id,
            created_at: event.created_at,
            created_by_name: event.created_by&.name
          }
        end

        def serialize_attributes(attributes)
          attributes.to_h.transform_values { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value }
        end

        def downstream_impact_required?(adjustment)
          unless defined?(@latest_reportable_pay_date)
            @latest_reportable_pay_date = PayPeriod.reportable_committed.where(company_id: adjustment.company_id).maximum(:pay_date)
          end
          @latest_reportable_pay_date.present? && @latest_reportable_pay_date > adjustment.effective_pay_date
        end
      end
    end
  end
end
