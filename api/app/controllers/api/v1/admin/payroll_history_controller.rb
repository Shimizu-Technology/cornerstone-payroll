# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollHistoryController < BaseController
        def index
          result = PayrollHistoryQuery.new(company_id: current_company_id, params: params).call
          review = current_company.payroll_go_live_review
          gate = PayrollGoLiveGate.new(company: current_company, pay_date: review&.effective_on || Date.current)
          render json: { data: result.data, meta: result.meta.merge(payroll_go_live: gate.state) }
        end
      end
    end
  end
end
