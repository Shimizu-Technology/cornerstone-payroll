# frozen_string_literal: true

module Api
  module V1
    module Admin
      class FinanceOverviewsController < BaseController
        before_action :require_admin!

        def show
          raise Date::Error unless params[:as_of].nil? || params[:as_of].is_a?(String)

          as_of = params[:as_of].present? ? Date.iso8601(params[:as_of]) : Date.current
          render json: FinanceOverviewSummary.new(finance_book: current_finance_book, as_of: as_of).call
        rescue Date::Error
          render json: { error: "As-of date must use YYYY-MM-DD" }, status: :unprocessable_entity
        end
      end
    end
  end
end
