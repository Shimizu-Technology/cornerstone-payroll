# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollLiabilitiesController < BaseController
        def index
          pay_period = PayPeriod.where(company_id: current_company_id).find(params[:pay_period_id])
          render json: {
            payroll_liability_reconciliation: PayrollLiabilityReconciliationService.new(pay_period: pay_period).call
          }
        end
      end
    end
  end
end
