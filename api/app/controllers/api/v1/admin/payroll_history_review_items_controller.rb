# frozen_string_literal: true

module Api
  module V1
    module Admin
      class PayrollHistoryReviewItemsController < BaseController
        before_action :require_selected_company!
        before_action :load_year

        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "Payroll history item not found" }, status: :not_found
        end
        rescue_from ArgumentError do |error|
          render json: { error: error.message }, status: :unprocessable_content
        end
        rescue_from ActiveRecord::RecordInvalid do |error|
          render json: { error: error.record.errors.full_messages.to_sentence }, status: :unprocessable_content
        end
        rescue_from PayrollHistoryReview::Resolution::Conflict do |error|
          render json: { error: error.message }, status: :conflict
        end
        rescue_from PayrollHistoryReview::Resolution::Forbidden do |error|
          render json: { error: error.message }, status: :forbidden
        end

        def index
          entries = detected_entries.sort_by { |item, _subject| [ item.resolved? ? 1 : 0, item.subject_type, item.id ] }
          render json: {
            data: entries.map { |entry| serialize(*entry) },
            can_review: StaffRolePolicy.allowed?(current_user, :review_payroll_history) && !current_company.test_workspace_read_only?
          }
        end

        def show
          item = scoped_item
          entry = detected_entries.find { |record, _subject| record.id == item.id }
          raise ActiveRecord::RecordNotFound unless entry

          render json: { data: serialize(*entry) }
        end

        def resolve
          entry = resolution.resolve!(code: params[:resolution_code], reference: params[:reference],
            expected_digest: params[:subject_digest]) { revalidate_current_company_write_access! }

          render json: { data: serialize(*entry) }
        end

        def reopen
          entry = resolution.reopen!(reason: params[:reason], expected_digest: params[:subject_digest]) do
            revalidate_current_company_write_access!
          end

          render json: { data: serialize(*entry) }
        end

        private

        def require_selected_company!
          return if request.headers["X-Company-Id"].present? && current_company &&
            current_user.can_access_company?(current_company.id)

          render json: { error: "Select a client for payroll history review" }, status: :unprocessable_content
        end

        def load_year
          @tax_year = Integer(params[:year].to_s, 10, exception: false)
          raise ArgumentError, "Choose a valid tax year" unless @tax_year&.between?(1900, Date.current.year + 1)
        end

        def detected_entries
          PayrollHistoryReview::Detector.new(company: current_company, tax_year: @tax_year).call(apply: true).fetch(:items)
        end

        def scoped_item
          PayrollHistoryReviewItem.where(company: current_company, tax_year: @tax_year).find(params[:id])
        end

        def resolution
          PayrollHistoryReview::Resolution.new(item: scoped_item, user: current_user, actor: Current.actor)
        end

        def serialize(item, subject)
          item.attributes.slice("id", "tax_year", "subject_type", "subject_digest", "status",
            "resolution_code", "resolution_reference", "resolved_at", "reopened_at").merge(
              resolved_by: item.resolved_by&.name, facts: subject.facts, resolution_codes: item.available_resolution_codes)
        end
      end
    end
  end
end
