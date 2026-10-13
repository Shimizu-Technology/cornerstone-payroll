# frozen_string_literal: true

module RecurringPayItemSetupMutation
  extend ActiveSupport::Concern

  private

  def with_recurring_pay_item_setup_invalidation
    ApplicationRecord.transaction(requires_new: true) do
      company = Company.lock.find(current_company_id)
      @payroll_field&.reload
      change = RecurringPayItemSetupChange.new(company: company, employee_ids: @employee ? [ @employee.id ] : nil)
      yield
      raise ActiveRecord::Rollback unless response.successful?

      @recalculation_pay_period_ids = change.invalidate_changed!
      payload = JSON.parse(response.body)
      payload["recalculation_pay_period_ids"] = @recalculation_pay_period_ids
      response.body = JSON.generate(payload)
    end
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    # The action may already have rendered a successful create/edit response.
    # The transaction has rolled back, so discard it before returning failure.
    self.response_body = nil
    # Rails 8 resets the HTTP body for nil but keeps its controller render marker.
    @_response_body = nil
    errors = e.record&.errors&.full_messages.presence || [ e.message ]
    render json: { errors: errors }, status: :unprocessable_entity
  end
end
