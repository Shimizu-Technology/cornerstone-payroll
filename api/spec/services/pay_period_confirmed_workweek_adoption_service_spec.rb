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

  it "keeps entered payroll rows but clears a stale calculation after adoption" do
    item = create(:payroll_item, pay_period: pay_period, company: company)
    pay_period.update_columns(calculated_at: Time.current, calculated_by_id: actor.id)

    described_class.call!(pay_period: pay_period, actor: actor)

    expect(pay_period.reload).to have_attributes(
      company_workweek: confirmed_workweek,
      calculated_at: nil,
      calculated_by_id: nil
    )
    expect(pay_period.payroll_items).to contain_exactly(item)
    expect(AuditLog.last.metadata).to include("calculation_invalidated" => true)
  end

  it "still refuses to detach imported source evidence from its captured workweek" do
    create(
      :time_tracking_import,
      pay_period: pay_period,
      time_tracking_source: create(:time_tracking_source, company: company)
    )

    expect {
      described_class.call!(pay_period: pay_period, actor: actor)
    }.to raise_error(described_class::AdoptionError, /imported source evidence/)

    expect(pay_period.reload.company_workweek).to eq(legacy_workweek)
  end
end
