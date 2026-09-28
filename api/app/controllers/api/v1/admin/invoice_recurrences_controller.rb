# frozen_string_literal: true

module Api
  module V1
    module Admin
      class InvoiceRecurrencesController < BaseController
        before_action :require_admin!

        def index
          rows = InvoiceRecurrence.where(organization_id: current_organization_id).order(:id)
          render json: { invoice_recurrences: rows.map { |row| payload(row) } }
        end

        def create
          source = Invoice.find_by(id: params.require(:source_invoice_id), organization_id: current_organization_id)
          return render json: { error: "Invoice not found" }, status: :not_found unless source
          raise ArgumentError, "Issue a native invoice before making it recurring" unless source.origin == "native" && source.open?

          recurrence = InvoiceRecurrence.create!(
            organization_id: current_organization_id,
            source_invoice: source,
            created_by: current_user,
            start_on: Date.iso8601(params.require(:start_on)),
            next_on: Date.iso8601(params.require(:start_on)),
            ends_on: params[:ends_on].presence && Date.iso8601(params[:ends_on]),
            interval_unit: params.require(:interval_unit),
            interval_count: params[:interval_count].presence || 1,
            due_after_days: params[:due_after_days].presence || 30,
            time_zone: params[:time_zone].presence || "Pacific/Guam"
          )
          render json: { invoice_recurrence: payload(recurrence) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        rescue ActiveRecord::RecordNotUnique
          render json: { error: "Invoice already has an active recurrence" }, status: :unprocessable_entity
        rescue ArgumentError, Date::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def update
          recurrence = scoped.find(params[:id])
          recurrence.update!(active: ActiveModel::Type::Boolean.new.cast(params.require(:active)))
          render json: { invoice_recurrence: payload(recurrence) }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Recurrence not found" }, status: :not_found
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def scoped
          InvoiceRecurrence.where(organization_id: current_organization_id)
        end

        def payload(row)
          row.as_json(only: %i[id organization_id source_invoice_id start_on next_on ends_on interval_unit interval_count
                               occurrence_index due_after_days time_zone active created_at])
        end
      end
    end
  end
end
