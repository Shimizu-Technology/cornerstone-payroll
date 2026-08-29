# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriodConfirmedWorkweekAdoptionService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization) }
  let!(:legacy_workweek) do
    company.company_workweeks.create!(
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 8, 28)
    )
  end
  let!(:confirmed_workweek) do
    company.company_workweeks.create!(
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: actor,
      confirmed_at: Time.current,
      notes: "Confirmed with the employer",
      effective_on: Date.new(2026, 8, 29)
    )
  end
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 15),
      pay_date: Date.new(2026, 8, 31),
      company_workweek: legacy_workweek
    )
  end

  it "rolls back the adoption if its audit event cannot be recorded" do
    confirmed_workweek
    allow(AuditLog).to receive(:record!).and_raise(ActiveRecord::RecordInvalid.new(AuditLog.new))

    expect {
      described_class.call!(pay_period: pay_period, actor: actor)
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(pay_period.reload.company_workweek).to eq(legacy_workweek)
  end
end
