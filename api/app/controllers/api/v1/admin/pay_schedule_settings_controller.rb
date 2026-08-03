# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayScheduleSettingsController < BaseController
        def show
          render json: payload(current_schedule, current_workweek)
        end

        def update
          schedule, workweek = CompanyPayScheduleChangeService.call!(
            company: current_company,
            actor: current_user,
            effective_on: Date.iso8601(settings_params.fetch(:effective_on)),
            schedule_attributes: schedule_params,
            workweek_attributes: workweek_params
          )

          render json: payload(schedule, workweek)
        rescue KeyError, Date::Error, ArgumentError, TypeError => e
          render json: { error: "Invalid effective date: #{e.message}" }, status: :unprocessable_entity
        rescue CompanyPayScheduleChangeService::ChangeError => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
        end

        private

        def settings_params
          params.require(:pay_schedule_settings).permit(
            :effective_on,
            pay_schedule: [ :frequency, :period_rule, :period_start_weekday, :period_anchor_date, :pay_date_rule, :pay_date_offset_days, :timezone, :notes ],
            workweek: [ :starts_on_weekday, :starts_at_minutes, :timezone, :notes ]
          )
        end

        def schedule_params
          settings_params.fetch(:pay_schedule).to_h.symbolize_keys
        end

        def workweek_params
          settings_params.fetch(:workweek).to_h.symbolize_keys
        end

        def current_schedule
          CompanyPaySchedule.for_date(current_company_id, configuration_date)
        end

        def current_workweek
          CompanyWorkweek.for_date(current_company_id, configuration_date)
        end

        def configuration_date
          Time.find_zone!("Pacific/Guam").today
        end

        def payload(schedule, workweek)
          {
            pay_schedule_settings: {
              pay_schedule: serialize_schedule(schedule),
              workweek: serialize_workweek(workweek)
            }
          }
        end

        def serialize_schedule(schedule)
          schedule ||= current_company.company_pay_schedules.build(
            frequency: current_company.pay_frequency,
            period_rule: "manual",
            pay_date_rule: "manual",
            timezone: "Pacific/Guam",
            source: "legacy_system_default",
            confirmation_status: "needs_confirmation",
            effective_on: configuration_date
          )
          schedule.as_json(only: [
            :id, :frequency, :period_rule, :period_start_weekday, :period_anchor_date, :pay_date_rule,
            :pay_date_offset_days, :timezone, :source, :confirmation_status,
            :confirmed_at, :effective_on, :ends_on, :notes
          ])
        end

        def serialize_workweek(workweek)
          workweek ||= current_company.company_workweeks.build(
            starts_on_weekday: 0,
            starts_at_minutes: 0,
            timezone: "Pacific/Guam",
            source: "legacy_system_default",
            confirmation_status: "needs_confirmation",
            effective_on: configuration_date
          )
          workweek.as_json(only: [
            :id, :starts_on_weekday, :starts_at_minutes, :timezone, :source,
            :confirmation_status, :confirmed_at, :effective_on, :ends_on, :notes
          ])
        end
      end
    end
  end
end
