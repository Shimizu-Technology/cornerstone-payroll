# frozen_string_literal: true

module Api
  module V1
    module EmployeePortal
      # What the employee app needs to open a link: who it is for, whether the
      # job is current or former, the company's switches, and the next payday
      # when it is known for certain.
      class ContextController < BaseController
        FEATURES = %i[stubs tax_forms profile_requests delivery_consent].freeze

        def show
          response.headers["Cache-Control"] = "no-store"
          features = CompanyFeatures.for(employee_access_context.company)
          render json: {
            first_name: employee_access_context.employee.first_name.to_s.squish.presence,
            status: employee_access_context.status,
            former_access_until: former_access_date&.iso8601,
            next_payday: next_payday&.iso8601,
            # How paper W-2s reach employees: "mailed", "handed_out", or nil when not set (M4-5).
            w2_delivery: employee_access_context.company.w2_delivery,
            demo: employee_access_context.company.demo?,
            features: FEATURES.index_with { |feature| feature_open?(features, feature) }
          }
        end

        private

        # Profile cards close at a former link's original cutoff, even while a
        # posted W-2GU copy keeps tax forms and stubs open (M4-5).
        def feature_open?(features, feature)
          return false unless features.employee_portal_feature?(feature)

          feature != :profile_requests || employee_access_context.profile_access_open?
        end

        # The last Guam day of read-only access (former_access_until is the end of that day).
        def former_access_date
          return unless employee_access_context.former? && employee_access_context.former_access_until

          employee_access_context.former_access_until.in_time_zone(PayrollBusinessClock::TIME_ZONE).to_date
        end

        # The settled next regular payday (EmployeeProfiles::NextPayday, §8a).
        def next_payday
          EmployeeProfiles::NextPayday.period(employee_access_context)&.pay_date
        end
      end
    end
  end
end
