# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollHistoryController < BaseController
        def index
          result = PayrollHistoryQuery.new(company_id: current_company_id, params: params).call
          review = current_company.payroll_go_live_review
          gate = PayrollGoLiveGate.new(company: current_company, pay_date: review&.effective_on || Date.current)
          render json: { data: result.data, meta: result.meta.merge(payroll_go_live: gate.state,
            prior_provider_history_available: PriorProviderHistory::Discovery.available?(current_company),
            **recorded_history_meta) }
        end

        private

        # Recorded history stays out of this list until year-to-date is turned
        # on, so the page has to say where those pay runs went.
        def recorded_history_meta
          # Each tax year has its own history, so more than one can be waiting.
          recorded = PriorProviderHistoryOnboarding.where(company_id: current_company_id, status: "converted")
          return {} unless recorded.exists?

          period_count = HistoricalPayPeriod.where(historical_import_batch_id: recorded.select(:historical_import_batch_id)).count
          { prior_provider_history_recorded: { period_count: period_count } }
        end
      end
    end
  end
end
