# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::Publisher do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let(:actor) { create(:user, company: company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let!(:schedule) do
    CompanyPaySchedule.create!(
      company: company,
      frequency: "semimonthly",
      period_rule: "semimonthly",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: actor,
      confirmed_at: Time.current,
      effective_on: Date.new(2026, 1, 1),
      notes: "Confirmed semimonthly calendar"
    )
  end
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: actor,
      confirmed_at: Time.current,
      effective_on: Date.new(2026, 1, 1),
      notes: "Confirmed Sunday workweek"
    )
  end
  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      company_pay_schedule: schedule,
      company_workweek: workweek,
      start_date: Date.new(2026, 10, 1),
      end_date: Date.new(2026, 10, 15),
      pay_date: Date.new(2026, 10, 25)
    )
  end
  let(:now) { Time.find_zone!("Pacific/Guam").local(2026, 10, 10, 9) }

  before do
    allow(AirePayrollCalendarPublication).to receive(:dispatch_one!)
  end

  it "creates one versioned T-7 Guam publication and queues delivery" do
    result = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call

    expect(result.created).to be(true)
    expect(result.publication).to have_attributes(schedule_version: 1, delivery_status: "pending")
    expect(result.publication.payload).to include(
      "start_date" => "2026-10-01",
      "end_date" => "2026-10-15",
      "pay_date" => "2026-10-25",
      "cutoff_at" => "2026-10-18T17:00:00+10:00",
      "time_zone" => "Pacific/Guam",
      "cutoff_days_before" => 7
    )
    expect(AirePayrollCalendarPublication).to have_received(:dispatch_one!).with(result.publication.id, now: now)
    expect(AuditLog.find_by!(action: "aire_payroll_calendar#published").company_id).to eq(company.id)
  end

  it "returns the same publication when the contract has not changed" do
    first = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    second = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call

    expect(second.created).to be(false)
    expect(second.publication).to eq(first.publication)
    expect(first.calendar_period.publications.count).to eq(1)
  end

  it "appends the next revision when dates change before cutoff" do
    first = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    first.publication.update!(delivery_status: "delivered", delivered_at: now)
    pay_period.update!(pay_date: Date.new(2026, 10, 26))

    revised = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call

    expect(revised.publication.schedule_version).to eq(2)
    expect(revised.publication.payload["cutoff_at"]).to eq("2026-10-19T17:00:00+10:00")
    expect(first.calendar_period.publications.order(:schedule_version).pluck(:schedule_version)).to eq([ 1, 2 ])
  end

  it "refuses to rewrite a delivered calendar after its cutoff" do
    first = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    first.publication.update!(delivery_status: "delivered", delivered_at: now)
    pay_period.update_column(:pay_date, Date.new(2026, 10, 26))

    expect do
      described_class.new(
        pay_period: pay_period.reload,
        source: source,
        actor: actor,
        now: Time.find_zone!("Pacific/Guam").local(2026, 10, 18, 17)
      ).call
    end.to raise_error(described_class::ConflictError, /cutoff has passed/)
  end

  it "does not create an undeliverable first publication after cutoff" do
    expect do
      described_class.new(
        pay_period: pay_period,
        source: source,
        actor: actor,
        now: Time.find_zone!("Pacific/Guam").local(2026, 10, 18, 17)
      ).call
    end.to raise_error(described_class::ConflictError, /already passed/)

    expect(AirePayrollCalendarPublication.count).to eq(0)
  end

  it "rejects non-semimonthly periods and unrelated sources" do
    pay_period.update!(start_date: Date.new(2026, 10, 2))
    other_source = create(:time_tracking_source, source_type: "aire_services")

    expect do
      described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    end.to raise_error(AirePayrollCalendar::Contract::Error, /1st–15th/)
    expect do
      described_class.new(pay_period: pay_period, source: other_source, actor: actor, now: now).call
    end.to raise_error(described_class::Error, /does not belong/)
  end
end
