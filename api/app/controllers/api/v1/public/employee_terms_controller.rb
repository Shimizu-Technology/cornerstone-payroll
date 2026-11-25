# frozen_string_literal: true

module Api
  module V1
    module Public
      class EmployeeTermsController < ActionController::API
        def show
          response.headers["Cache-Control"] = "no-store"
          terms = EmployeeTermsVersion.current
          unless terms
            return render json: { error: "Sign-up is unavailable because the Employee App Terms have not been published." },
              status: :service_unavailable
          end

          render json: {
            version: terms.version, title: EmployeeTermsVersion::TITLE,
            effective_date: terms.published_at.in_time_zone("Guam").to_date.iso8601,
            text_digest: terms.text_digest, terms_url: terms.terms_url, privacy_url: terms.privacy_url
          }
        end
      end
    end
  end
end
