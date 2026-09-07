# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollHistoryController < BaseController
        def index
          result = PayrollHistoryQuery.new(company_id: current_company_id, params: params).call
          render json: { data: result.data, meta: result.meta }
        end
      end
    end
  end
end
