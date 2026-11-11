# frozen_string_literal: true

require "rails_helper"

# Pins the publication AIRE receives for an admin lock time. AIRE's suite
# (spec/requests/api/v1/payroll/calendar_cutoff_override_contract_spec.rb)
# replays the same fixture, so keep the two copies identical.
RSpec.describe "AIRE lock-time publication contract" do
  include ActiveSupport::Testing::TimeHelpers

  let(:guam) { Time.find_zone!("Pacific/Guam") }
  let(:fixture) { JSON.parse(file_fixture("aire_cutoff_override_publication.json").read) }
  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let(:chels) { create(:user, company: company, organization: company.organization, role: "org_admin", name: "Chels") }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", cutoff_enforcement_starts_on: Date.new(2026, 10, 16)) }
  let!(:schedule) do
    CompanyPaySchedule.create!(
      company: company, frequency: "semimonthly", period_rule: "semimonthly",
      pay_date_rule: "semimonthly_15th_and_month_end", time_tracking_cutoff_rule: "after_previous_regular_payday",
      time_tracking_cutoff_days: 7, payroll_cutoff_at_minutes: 1020, timezone: "Pacific/Guam",
      source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: chels,
      confirmed_at: Time.current, effective_on: Date.new(2026, 1, 1), notes: "Confirmed"
    )
  end
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company, starts_on_weekday: 0, starts_at_minutes: 0, timezone: "Pacific/Guam",
      source: "operator_confirmed", confirmation_status: "confirmed", confirmed_by: chels,
      confirmed_at: Time.current, effective_on: Date.new(2026, 1, 1), notes: "Confirmed"
    )
  end
  let!(:previous_regular) do
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15))
  end
  let(:pay_period) do
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 30))
  end

  before do
    travel_to(guam.local(2026, 11, 18, 9))
    allow(AirePayrollCalendarPublication).to receive(:dispatch_one!)
  end
  after { travel_back }

  it "publishes exactly the pinned override payload" do
    AirePayrollCalendar::Publisher.new(pay_period: pay_period, source: source, actor: chels).call.publication
      .update_columns(delivery_status: "delivered", delivered_at: Time.current, next_delivery_attempt_at: nil)
    result = AirePayrollCalendar::CutoffChange.new(
      pay_period: pay_period, action: "change", cutoff_at: "2026-11-21T12:00:00+10:00",
      reason: "Thanksgiving payroll run", actor: chels
    ).call

    payload = result.publication.payload
    expected = fixture.deep_merge(
      "publication_id" => result.publication.publication_id,
      "cutoff_override" => { "override_id" => result.override.override_id }
    )
    expect(payload).to eq(expected)
  end

  it "publishes the policy payload shape with only cutoff_source added" do
    payload = AirePayrollCalendar::Publisher.new(pay_period: pay_period, source: source, actor: chels).call.publication.payload

    policy = fixture.except("policy_cutoff_at", "cutoff_override").merge(
      "cutoff_at" => "2026-11-22T17:00:00+10:00", "cutoff_source" => "policy",
      "schedule_version" => 1, "publication_id" => payload.fetch("publication_id")
    )
    expect(payload).to eq(policy)
  end

  it "does not report publications made before cutoff_source existed as needing an update" do
    publication = AirePayrollCalendar::Publisher.new(pay_period: pay_period, source: source, actor: chels).call.publication
    legacy = publication.payload.except("cutoff_source")
    publication.update_columns(payload: legacy, delivery_status: "delivered", delivered_at: Time.current)

    state = AirePayrollCalendar::Presenter.call(pay_period.reload)
    expect(state).to include(needs_revision: false, cutoff_source: "policy")
    expect(AirePayrollCalendar::Publisher.new(pay_period: pay_period, source: source, actor: chels).call.created).to be(false)
  end
end
