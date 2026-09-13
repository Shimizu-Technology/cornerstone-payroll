# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollLiabilityCenterController < BaseController
        def show
          render json: { payroll_liability_center: center_payload }
        end

        def update_due_date
          period = PayPeriod.where(company_id: current_company_id).find(due_date_params.fetch(:pay_period_id))
          authority = due_date_params.fetch(:authority).to_s.strip
          raise ArgumentError, "Recipient is required" if authority.blank?
          unless active_obligation_exists?(period, authority)
            return render json: { error: "Payroll liability was not found" }, status: :not_found
          end

          record = PayrollLiabilityObligationDueDate.find_or_initialize_by(
            pay_period: period,
            authority:
          )
          record.assign_attributes(
            company: current_company,
            due_date: Date.iso8601(due_date_params.fetch(:due_date)),
            updated_by: current_user
          )
          record.save!

          render json: { payroll_liability_center: center_payload }
        rescue Date::Error
          render json: { error: "Due date is invalid" }, status: :unprocessable_entity
        rescue ArgumentError, ActiveRecord::RecordInvalid => e
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def due_date_params
          params.require(:payroll_liability_obligation).permit(:pay_period_id, :authority, :due_date)
        end

        def center_payload
          PayrollLiabilityCenterService.new(company: current_company).call
        end

        def active_obligation_exists?(period, authority)
          reversed_source_ids = PayrollLiabilityPosting.reversals.select(:source_posting_id)
          period.payroll_liability_postings.source_postings.where.not(id: reversed_source_ids)
            .joins(:entries)
            .where(payroll_liability_entries: { authority: })
            .exists?
        end
      end
    end
  end
end
