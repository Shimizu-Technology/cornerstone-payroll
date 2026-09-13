# frozen_string_literal: true

module Api
  module V1
    module Admin
      class AirePayrollCalendarsController < BaseController
        before_action :set_pay_period

        def show
          render json: { aire_payroll_calendar: AirePayrollCalendar::Presenter.call(@pay_period) }
        end

        def publish
          result = AirePayrollCalendar::Publisher.new(
            pay_period: @pay_period,
            source: active_aire_source!,
            actor: current_user
          ).call
          render json: {
            aire_payroll_calendar: AirePayrollCalendar::Presenter.call(@pay_period.reload),
            created: result.created
          }, status: result.created ? :created : :ok
        rescue AirePayrollCalendar::Publisher::ConflictError => e
          render json: { error: e.message }, status: :conflict
        rescue AirePayrollCalendar::Contract::Error, AirePayrollCalendar::Publisher::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        def retry_delivery
          publication = @pay_period.aire_payroll_calendar_period&.latest_publication
          return render json: { error: "Publish this pay period to AIRE first" }, status: :unprocessable_entity unless publication
          return render json: { aire_payroll_calendar: AirePayrollCalendar::Presenter.call(@pay_period) } if publication.delivered?

          publication.update!(next_delivery_attempt_at: Time.current, delivery_enqueued_until: nil)
          AirePayrollCalendarPublication.dispatch_one!(publication.id)
          render json: { aire_payroll_calendar: AirePayrollCalendar::Presenter.call(@pay_period.reload) }
        end

        private

        def set_pay_period
          @pay_period = PayPeriod.find_by!(id: params[:pay_period_id], company_id: current_company_id)
        end

        def active_aire_source!
          current_company.time_tracking_sources.active.find_by!(source_type: "aire_services")
        rescue ActiveRecord::RecordNotFound
          raise AirePayrollCalendar::Publisher::Error, "This client does not have an active AIRE Services source"
        end
      end
    end
  end
end
