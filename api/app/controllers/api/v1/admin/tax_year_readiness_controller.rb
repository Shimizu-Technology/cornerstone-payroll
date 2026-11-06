# frozen_string_literal: true

module Api
  module V1
    module Admin
      class TaxYearReadinessController < BaseController
        def show
          dates = PayPeriod.where(company_id: current_company_id).where.not(status: "committed").distinct.pluck(:pay_date)
          render json: TaxYearReadiness.new(pay_dates: dates).as_json
        end
      end
    end
  end
end
