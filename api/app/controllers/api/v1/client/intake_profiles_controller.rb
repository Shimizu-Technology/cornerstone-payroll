# frozen_string_literal: true

module Api
  module V1
    module Client
      class IntakeProfilesController < BaseController
        # GET /api/v1/client/intake_profile?on=YYYY-MM-DD
        def show
          as_of = parse_as_of_date
          return unless as_of

          render json: PayrollIntake::ProfileBuilder.new(company: current_company, on: as_of, audience: :client).call
        end

        private

        def parse_as_of_date
          return PayrollBusinessClock.today if params[:on].blank?

          raw = params[:on].to_s.strip
          unless raw.match?(/\A\d{4}-\d{2}-\d{2}\z/)
            render json: { error: "Invalid date parameter 'on'. Expected YYYY-MM-DD." }, status: :unprocessable_entity
            return nil
          end

          Date.iso8601(raw)
        rescue Date::Error
          render json: { error: "Invalid date parameter 'on'. Expected YYYY-MM-DD." }, status: :unprocessable_entity
          nil
        end
      end
    end
  end
end
