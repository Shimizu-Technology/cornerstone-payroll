# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PunchEntriesController < BaseController
        before_action :set_punch_entry

        # PATCH /api/v1/admin/punch_entries/:id
        def update
          attrs = punch_entry_params.to_h
          attrs[:manually_edited] = true if punch_field_changed?(attrs)

          @punch_entry.update!(attrs)

          render json: punch_entry_json(@punch_entry)
        end

        private

        def set_punch_entry
          @punch_entry = PunchEntry.find(params[:id])
          unless @punch_entry.timecard.company_id == current_company_id
            render json: { error: "Not found" }, status: :not_found
          end
        end

        def punch_entry_params
          params.require(:punch_entry).permit(
            :date, :clock_in, :lunch_out, :lunch_in, :clock_out, :in3, :out3,
            :notes, :confidence, :review_state, :reviewed_by_name
          )
        end

        def punch_field_changed?(attrs)
          %w[clock_in lunch_out lunch_in clock_out in3 out3].any? { |f| attrs.key?(f) }
        end

        def punch_entry_json(pe)
          {
            id: pe.id,
            timecard_id: pe.timecard_id,
            card_day: pe.card_day,
            date: pe.date,
            day_of_week: pe.day_of_week,
            clock_in: pe.clock_in&.strftime("%H:%M"),
            lunch_out: pe.lunch_out&.strftime("%H:%M"),
            lunch_in: pe.lunch_in&.strftime("%H:%M"),
            clock_out: pe.clock_out&.strftime("%H:%M"),
            in3: pe.in3&.strftime("%H:%M"),
            out3: pe.out3&.strftime("%H:%M"),
            hours_worked: pe.hours_worked,
            confidence: pe.confidence,
            notes: pe.notes,
            manually_edited: pe.manually_edited,
            review_state: pe.review_state,
            reviewed_by_name: pe.reviewed_by_name,
            reviewed_at: pe.reviewed_at,
            needs_attention: pe.needs_attention?,
            blank_day: pe.blank_day?
          }
        end
      end
    end
  end
end
