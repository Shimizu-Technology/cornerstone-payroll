# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendarPeriod do
  it "keeps calendar identity immutable after creation" do
    calendar_period = create(:aire_payroll_calendar_period)

    expect do
      calendar_period.update!(external_pay_period_id: SecureRandom.uuid)
    end.to raise_error(ActiveRecord::RecordInvalid, /identity is immutable/)
  end

  it "enforces the source tenant even when validations are bypassed" do
    calendar_period = create(:aire_payroll_calendar_period)
    other_source = create(:time_tracking_source, source_type: "aire_services")

    expect do
      calendar_period.update_columns(time_tracking_source_id: other_source.id)
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end

  it "enforces the pay-period tenant even when validations are bypassed" do
    calendar_period = create(:aire_payroll_calendar_period)
    other_pay_period = create(:pay_period)

    expect do
      calendar_period.update_columns(pay_period_id: other_pay_period.id)
    end.to raise_error(ActiveRecord::InvalidForeignKey)
  end
end
