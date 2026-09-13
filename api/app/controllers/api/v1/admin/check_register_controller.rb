# frozen_string_literal: true

require "csv"

module Api
  module V1
    module Admin
      class CheckRegisterController < BaseController
        def index
          render json: { check_register: register }
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def create_event
          event = ActiveRecord::Base.transaction do
            created_event = CheckReconciliationEventService.new(
              company: current_company,
              actor: current_user,
              attributes: event_params
            ).call
            record_event_audit!(created_event)
            created_event
          end
          skip_default_audit_log!

          render json: { event: event_payload(event) }, status: :created
        rescue CheckReconciliationEventService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def export
          payload = register
          send_data generate_csv(payload),
                    filename: "check_register_#{payload[:from]}_through_#{payload[:to]}.csv",
                    type: "text/csv; charset=utf-8",
                    disposition: "attachment"
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def register
          CheckRegisterService.new(
            company: current_company,
            from: params[:from].presence || PayrollBusinessClock.today.beginning_of_year.iso8601,
            to: params[:to].presence || PayrollBusinessClock.today.iso8601,
            status: params[:status]
          ).call
        end

        def event_params
          params.require(:event).permit(
            :source_type,
            :source_id,
            :event_type,
            :effective_on,
            :evidence_type,
            :evidence_reference,
            :reason,
            :idempotency_key
          )
        end

        def event_payload(event)
          {
            id: event.id,
            source_type: event.payroll_item_id ? "payroll_item" : "non_employee_check",
            source_id: event.payroll_item_id || event.non_employee_check_id,
            event_type: event.event_type,
            check_number: event.check_number,
            amount: event.amount.to_f,
            effective_on: event.effective_on,
            evidence_type: event.evidence_type,
            evidence_reference: event.evidence_reference,
            reason: event.reason,
            recorded_by: event.recorded_by.name,
            created_at: event.created_at
          }
        end

        def record_event_audit!(event)
          AuditLog.record!(
            user: current_user,
            organization_id: current_company.organization_id,
            company_id: current_company.id,
            action: "check_register##{event.event_type}",
            record_type: "check_reconciliation_events",
            record_id: event.id,
            subject_name: "Check ##{event.check_number}",
            metadata: {
              source_type: event.payroll_item_id ? "payroll_item" : "non_employee_check",
              source_id: event.payroll_item_id || event.non_employee_check_id,
              amount: event.amount.to_s,
              effective_on: event.effective_on,
              evidence_type: event.evidence_type,
              evidence_reference: event.evidence_reference,
              reason: event.reason
            }.compact,
            ip_address: request.remote_ip,
            user_agent: request.user_agent,
            request_id: request.request_id,
            event_category: "activity"
          )
        end

        def generate_csv(payload)
          CSV.generate do |csv|
            csv << [
              "Register Date", "Check Number", "Payee", "Amount", "Type", "Payment Status",
              "Reconciliation", "Issued On", "Issued By", "Issuance Method", "Issuance Reference",
              "Evidence Date", "Evidence Type", "Evidence Reference", "Reason", "Previous Check Numbers"
            ]
            payload[:rows].each do |row|
              event = row[:latest_reconciliation_event]
              csv << [
                row[:register_date], row[:check_number], row[:payee], format("%.2f", row[:amount]),
                row[:source_type], row[:status], row[:reconciliation_status], row[:issued_on], row[:issued_by],
                row[:issuance_method], row[:issuance_reference], event&.dig(:effective_on), event&.dig(:evidence_type),
                event&.dig(:evidence_reference), event&.dig(:reason), row[:previous_check_numbers].join("; ")
              ]
            end
          end
        end
      end
    end
  end
end
