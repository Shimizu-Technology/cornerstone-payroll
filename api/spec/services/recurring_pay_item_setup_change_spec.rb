# frozen_string_literal: true

require "rails_helper"

RSpec.describe RecurringPayItemSetupChange do
  it "does not inspect employee setup when this client has no reviewable payroll" do
    company = create(:company)
    employee = create(:employee, company: company)
    field = create(:payroll_field_definition, company: company)
    employee.employee_payroll_fields.create!(payroll_field_definition: field, amount: 250)
    create(:pay_period, company: company)
    create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 10, 15))
    setup_queries = []
    subscriber = lambda do |_name, _start, _finish, _id, payload|
      setup_queries << payload[:sql] if payload[:sql].match?(/FROM\s+"(?:employees|employee_payroll_fields|payroll_field_definitions)"/)
    end
    result = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      change = described_class.new(company: company)
      change.invalidate_changed!
    end
    expect(result).to eq([])
    expect(setup_queries).to be_empty
  end
end
