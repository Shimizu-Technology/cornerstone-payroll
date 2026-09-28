# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceSendSchedulesController < BaseController
        before_action :require_admin!

        def index
          rows = scoped.order(send_at: :desc, id: :desc)
          render json: { invoice_send_schedules: rows.map { |row| payload(row) } }
        end

        def create
          invoice = Invoice.find_by(id: params.require(:invoice_id), finance_book_id: current_finance_book.id)
          return render json: { error: "Invoice not found" }, status: :not_found unless invoice
          raise ArgumentError, "Only unpaid open invoices can be scheduled for email" unless invoice.open? && invoice.balance_due.positive?
          raise ArgumentError, "An issued PDF is required" unless invoice.primary_artifact&.content_type == "application/pdf"

          recipients = InvoiceSendSchedule.normalize_recipients(params[:recipients].presence || invoice.invoice_recipient.email)
          send_now = ActiveModel::Type::Boolean.new.cast(params[:send_now])
          send_at = send_now ? Time.current : Time.iso8601(params.require(:send_at))
          schedule = InvoiceSendSchedule.transaction do
            row = InvoiceSendSchedule.create!(
              organization: invoice.organization,
              finance_book: current_finance_book,
              invoice: invoice,
              created_by: current_user,
              recipients: recipients,
              send_at: send_at
            )
            InvoiceEvent.record!(invoice: invoice, event_type: "email_scheduled", actor: current_user,
                                 metadata: { send_schedule_id: row.id, send_at: send_at.iso8601, recipients: recipients })
            row
          end
          if send_now
            begin
              InvoiceSendJob.perform_later(schedule.id)
            rescue StandardError => e
              # The pending schedule remains durable. The minute dispatcher will
              # pick it up when the queue is available again.
              Rails.logger.error("Immediate invoice email enqueue failed for schedule #{schedule.id}: #{e.class}: #{e.message}")
            end
          end
          render json: { invoice_send_schedule: payload(schedule) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update
          schedule = scoped.find(params[:id])
          schedule.with_lock do
            if params[:retry] == true || params[:retry] == "true"
              raise ArgumentError, "Only failed invoice emails can be retried" unless schedule.status == "failed"
              if schedule.first_claimed_at.present? && schedule.first_claimed_at <= 24.hours.ago
                raise ArgumentError, "The provider idempotency window has expired; verify delivery and create a new schedule"
              end

              schedule.update!(status: "pending", last_error: nil)
              InvoiceEvent.record!(invoice: schedule.invoice, event_type: "email_retry_requested", actor: current_user,
                                   metadata: { send_schedule_id: schedule.id })
            elsif schedule.status != "pending"
              raise ArgumentError, "Only pending invoice emails can be cancelled or changed"
            elsif params[:cancel] == true || params[:cancel] == "true"
              schedule.update!(status: "cancelled")
              InvoiceEvent.record!(invoice: schedule.invoice, event_type: "email_schedule_cancelled", actor: current_user,
                                   metadata: { send_schedule_id: schedule.id })
            else
              raise ArgumentError, "A claimed email cannot be edited; create a new schedule" if schedule.attempts.positive?

              updates = {}
              updates[:send_at] = Time.iso8601(params[:send_at]) if params[:send_at].present?
              updates[:recipients] = InvoiceSendSchedule.normalize_recipients(params[:recipients]) if params.key?(:recipients)
              schedule.update!(updates)
              if updates.present?
                InvoiceEvent.record!(invoice: schedule.invoice, event_type: "email_schedule_updated", actor: current_user,
                                     metadata: { send_schedule_id: schedule.id, send_at: schedule.send_at.iso8601,
                                                 recipients: schedule.recipients })
              end
            end
          end
          render json: { invoice_send_schedule: payload(schedule) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Scheduled email not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ArgumentError => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def scoped
          InvoiceSendSchedule.where(finance_book_id: current_finance_book.id)
        end

        def payload(row)
          row.as_json(only: %i[id organization_id invoice_id recipients send_at status attempts provider_reference
                               last_error claimed_at sent_at created_at])
        end
      end
    end
  end
end
