# frozen_string_literal: true

module Api
  module V1
    module Admin
      class EmployeeTimeRecordsController < BaseController
        before_action :set_employee

        def index
          records = @employee.daily_time_records.current.order(work_date: :desc)
          records = records.where(work_date: Date.parse(params[:start_date])..) if params[:start_date].present?
          records = records.where(work_date: ..Date.parse(params[:end_date])) if params[:end_date].present?
          render json: { data: records.limit(366) }
        rescue Date::Error
          render json: { error: "Date filters must be valid dates" }, status: :unprocessable_entity
        end

        def create
          work_date = Date.parse(time_record_params.fetch(:work_date))
          workweek = CompanyWorkweek.for_date(current_company_id, work_date)
          return render json: { error: "Confirm the company's legal workweek before recording time" }, status: :unprocessable_entity unless workweek

          record = @employee.daily_time_records.create!(
            time_record_params.except(:work_date).merge(
              company_id: current_company_id,
              work_date: work_date,
              workweek_started_on: workweek_start(work_date, workweek.starts_on_weekday),
              source: "manual",
              ledger_key: "authoritative",
              employee_work_profile: @employee.work_profile_on(work_date)
            )
          )
          render json: { data: record }, status: :created
        rescue KeyError, Date::Error
          render json: { error: "A valid work date is required" }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        end

        def update
          record = @employee.daily_time_records.current.find(params[:id])
          replacement = DailyTimeRecordRevisionService.call!(record: record, attributes: time_record_params.except(:work_date))
          render json: { data: replacement }
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Time record not found" }, status: :not_found
        rescue DailyTimeRecordRevisionService::Error => e
          render json: { error: e.message }, status: :unprocessable_entity
        rescue ActiveRecord::RecordInvalid => e
          render json: { error: "Validation failed", details: e.record.errors.messages }, status: :unprocessable_entity
        end

        private

        def set_employee
          @employee = Employee.find_by(id: params[:employee_id], company_id: current_company_id)
          render json: { error: "Employee not found" }, status: :not_found unless @employee
        end

        def time_record_params
          params.require(:time_record).permit(
            :work_date,
            :scheduled_hours,
            :actual_worked_hours,
            :pto_hours,
            :holiday_hours,
            :exception_reason,
            :override_reason
          )
        end

        def workweek_start(date, start_weekday)
          date - ((date.wday - start_weekday) % 7).days
        end
      end
    end
  end
end
