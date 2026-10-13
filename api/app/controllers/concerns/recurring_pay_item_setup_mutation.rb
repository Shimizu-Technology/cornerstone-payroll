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

      if response.successful?
        @recalculation_pay_period_ids = change.invalidate_changed!
        payload = JSON.parse(response.body)
        payload["recalculation_pay_period_ids"] = @recalculation_pay_period_ids
        response.body = JSON.generate(payload)
      end
    end
  end
end
