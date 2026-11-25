# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # What the employee app needs to open a link: who it is for, whether the
      # job is current or former, the company's switches, and the next payday
      # when it is known for certain.
      class ContextController < BaseController
        FEATURES = %i[stubs tax_forms profile_requests].freeze
        OPEN_STATUSES = %w[draft calculated approved committed].freeze

        def show
          response.headers["Cache-Control"] = "no-store"
          features = CompanyFeatures.for(@employee_link.company)
          render json: {
            first_name: @employee_link.employee.first_name.to_s.squish.presence,
            status: @employee_link.status,
            former_access_until: former_access_date&.iso8601,
            next_payday: next_payday&.iso8601,
            # How paper W-2s reach employees: "mailed", "handed_out", or nil when not set (M4-5).
            w2_delivery: @employee_link.company.w2_delivery,
            features: FEATURES.index_with { |feature| feature_open?(features, feature) }
          }
        end

        private

        # Profile cards close at a former link's original cutoff, even while a
        # posted W-2GU copy keeps tax forms and stubs open (M4-5).
        def feature_open?(features, feature)
          return false unless features.employee_portal_feature?(feature)

          feature != :profile_requests || @employee_link.profile_access_open?
        end

        # The last Guam day of read-only access (former_access_until is the end of that day).
        def former_access_date
          return unless @employee_link.former? && @employee_link.former_access_until

          @employee_link.former_access_until.in_time_zone(PayrollBusinessClock::TIME_ZONE).to_date
        end

        # §8a: only from the company's next real regular pay run, and only
        # when its date is settled: a committed run, or a run created on a
        # confirmed pay schedule that sets its own dates (a manual-dates
        # draft's date is tentative). A void+redo correction run stands in
        # for the run it replaced, as in PayPeriod.reportable_periods. If the
        # next run's date isn't settled, the app shows nothing rather than
        # skip to a later one. Former employees never get one.
        def next_payday
          return if @employee_link.former?

          period = PayPeriod.where(company_id: @employee_link.company_id, status: OPEN_STATUSES, cycle: "regular",
            run_purpose: "regular", correction_status: [ nil, "correction" ], test_workspace_role: nil, parallel_run: false)
            .where(pay_date: PayrollBusinessClock.today..)
            .order(pay_date: :asc, id: :asc).first
          return unless period
          return period.pay_date if period.status == "committed"

          schedule = CompanyPaySchedule.find_by(id: period.company_pay_schedule_id, company_id: period.company_id)
          period.pay_date if schedule&.confirmed? && !schedule.manual_dates?
        end
      end
    end
  end
end
