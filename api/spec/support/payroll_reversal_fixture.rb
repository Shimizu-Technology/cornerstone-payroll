# frozen_string_literal: true

module PayrollReversalFixture
  def payroll_reversal_fixture
    {
      payroll_reversed_at: Time.current,
      payroll_reversed_by_id: create(:user, company: company).id,
      payroll_reversal_reason: "Reviewed financial reversal fixture"
    }
  end
end

RSpec.configure { |config| config.include PayrollReversalFixture }
