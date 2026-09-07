# frozen_string_literal: true

module Api
  module V1
    module Client
      class ImportedPayPeriodsController < BaseController
        def show
          result = ImportedPayPeriodQuery.new(
            company_id: current_company_id,
            id: params[:id],
            params: params,
            audience: :client
          ).call
          render json: { data: result.data, meta: result.meta }
        end
      end
    end
  end
end
