# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::Publisher do
  # These fixtures describe publication before the October 22 cutoff.
  # Model validations use Time.current as well as the presenter's explicit clock.
  before { travel_to(Time.find_zone!("Pacific/Guam").local(2026, 10, 17, 9)) }
  after { travel_back }

  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let(:actor) { create(:user, company: company) }
  let(:activation_date) { Date.new(2026, 10, 1) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services", cutoff_enforcement_starts_on: activation_date) }
  let!(:schedule) do
    CompanyPaySchedule.create!(
      company: company,
      frequency: "semimonthly",
      period_rule: "semimonthly",
      pay_date_rule: "semimonthly_15th_and_month_end",
      time_tracking_cutoff_rule: "after_previous_regular_payday",
      time_tracking_cutoff_days: 7,
      payroll_cutoff_at_minutes: 1020,
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
  let!(:previous_regular) do
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 9, 16), end_date: Date.new(2026, 9, 30), pay_date: Date.new(2026, 10, 15))
  end

  let(:pay_period) do
    create(
      :pay_period,
      company: company,
      company_pay_schedule: schedule,
      company_workweek: workweek,
      start_date: Date.new(2026, 10, 1),
      end_date: Date.new(2026, 10, 15),
      pay_date: Date.new(2026, 10, 31)
    )
  end
  let(:now) { Time.find_zone!("Pacific/Guam").local(2026, 10, 10, 9) }

  before do
    allow(AirePayrollCalendarPublication).to receive(:dispatch_one!)
  end

  it "blocks an existing source until its historical coverage is approved" do
    source.update!(historical_reconciliation_required: true)

    expect do
      described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    end.to raise_error(described_class::Error, /complete historical payroll reconciliation/)

    expect(source.aire_payroll_calendar_periods).to be_empty
    expect(AirePayrollCalendarPublication).not_to have_received(:dispatch_one!)
  end

  it "rejects adjustment publication with a provider-neutral explanation" do
    pay_period.update!(run_purpose: "adjustment")

    expect do
      described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    end.to raise_error(AirePayrollCalendar::Contract::Error, "Only regular payroll runs can publish a time-tracking calendar.") { |error|
      expect(error.code).to eq("unsupported_run")
    }

    expect(source.aire_payroll_calendar_periods).to be_empty
    expect(AirePayrollCalendarPublication).not_to have_received(:dispatch_one!)
  end

  it "creates one versioned previous-payday-plus-seven Guam publication and queues delivery" do
    result = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call

    expect(result.created).to be(true)
    expect(result.publication).to have_attributes(schedule_version: 1, delivery_status: "pending")
    expect(result.publication.payload).to include(
      "start_date" => "2026-10-01",
      "end_date" => "2026-10-15",
      "pay_date" => "2026-10-31",
      "cutoff_at" => "2026-10-22T17:00:00+10:00",
      "time_zone" => "Pacific/Guam",
      "schema_version" => "2.0",
      "cutoff_rule" => "after_previous_regular_payday",
      "cutoff_days" => 7,
      "previous_regular_pay_date" => "2026-10-15",
      "overtime_policy" => {
        "schema_version" => "2.0", "calculation" => "weekly_only", "weekly_threshold_hours" => 40.0,
        "workweek_start" => "sunday", "time_zone" => "Pacific/Guam"
      }
    )
    expect(AirePayrollCalendarPublication).to have_received(:dispatch_one!).with(result.publication.id, now: now)
    expect(AuditLog.find_by!(action: "aire_payroll_calendar#published").company_id).to eq(company.id)
  end

  it "rejects a shifted target payday even when a legacy record bypassed date validation" do
    pay_period.update_column(:pay_date, Date.new(2026, 10, 30))
    expect do
      described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    end.to raise_error(AirePayrollCalendar::Contract::Error, /fixed regular scheduled payday/)
    expect(source.aire_payroll_calendar_periods).to be_empty
  end

  it "rejects a shifted previous payday even when a legacy record bypassed date validation" do
    previous_regular.update_column(:pay_date, Date.new(2026, 10, 14))
    expect do
      described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    end.to raise_error(AirePayrollCalendar::Contract::Error, /previous regular payday must use the fixed/)
    expect(source.aire_payroll_calendar_periods).to be_empty
  end

  it "publishes an explicit weekly policy revision for a future legacy calendar" do
    allow_any_instance_of(AirePayrollCalendar::Contract).to receive(:payload).and_wrap_original do |method|
      method.call.except("overtime_policy")
    end
    first = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    allow_any_instance_of(AirePayrollCalendar::Contract).to receive(:payload).and_call_original

    updated = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call

    expect(updated.created).to be(true)
    expect(updated.publication.schedule_version).to eq(2)
    expect(updated.publication.payload.fetch("overtime_policy")).to eq(AirePayrollCalendar::Contract::OVERTIME_POLICY)
    expect(first.publication.reload.payload).not_to have_key("overtime_policy")
    expect(first.calendar_period.publications.count).to eq(2)
  end

  it "returns the same publication when the contract has not changed" do
    first = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    second = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call

    expect(second.created).to be(false)
    expect(second.publication).to eq(first.publication)
    expect(first.calendar_period.publications.count).to eq(1)
  end

  it "rejects non-AIRE cutoff configuration before creating an outbox publication" do
    [ { time_tracking_cutoff_rule: "before_pay_date" }, { time_tracking_cutoff_days: 5 }, { payroll_cutoff_at_minutes: 1080 } ].each do |invalid|
      schedule.update!(time_tracking_cutoff_rule: "after_previous_regular_payday", time_tracking_cutoff_days: 7, payroll_cutoff_at_minutes: 1020, **invalid)
      expect do
        described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
      end.to raise_error(AirePayrollCalendar::Contract::Error, /17:00 Guam/)
      expect(AirePayrollCalendarPublication.count).to eq(0)
    end
  end

  it "uses the adjacent regular period rather than an adjustment's check date" do
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: previous_regular.start_date, end_date: previous_regular.end_date,
      pay_date: Date.new(2026, 10, 20), run_purpose: "adjustment")
    result = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    expect(result.publication.payload).to include("previous_regular_pay_date" => "2026-10-15", "cutoff_at" => "2026-10-22T17:00:00+10:00")
  end

  it "requires an unambiguous previous regular period for the new cutoff rule" do
    previous_regular.destroy!

    expect do
      described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    end.to raise_error(AirePayrollCalendar::Contract::Error, /adjacent previous regular payroll period/)
  end

  it "uses the fixed regular scheduled payday and 5pm Guam even when the payday is a weekend" do
    schedule.update!(time_tracking_cutoff_rule: "after_previous_regular_payday", time_tracking_cutoff_days: 7, payroll_cutoff_at_minutes: 1020)
    previous = create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 7, 16), end_date: Date.new(2026, 7, 31), pay_date: Date.new(2026, 8, 15))
    target = create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 31))
    # An adjustment's later check date cannot move the anchor.
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: previous.start_date, end_date: previous.end_date, pay_date: Date.new(2026, 8, 20), run_purpose: "adjustment")
    result = described_class.new(pay_period: target, source: source, actor: actor,
      now: Time.find_zone!("Pacific/Guam").local(2026, 8, 16, 9)).call

    expect(result.publication.payload).to include("previous_regular_pay_date" => "2026-08-15", "cutoff_at" => "2026-08-22T17:00:00+10:00")
  end

  it "rejects workweeks that AIRE cannot classify instead of publishing an unimportable calendar" do
    workweek.update!(starts_on_weekday: 1)

    expect do
      described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    end.to raise_error(AirePayrollCalendar::Contract::Error, /Sunday midnight Guam/)
    expect(AirePayrollCalendarPublication.count).to eq(0)
  end

  it "appends the next revision when dates change before cutoff" do
    first = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    first.publication.update!(delivery_status: "delivered", delivered_at: now)
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15))
    pay_period.update!(start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 30))

    revised = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call

    expect(revised.publication.schedule_version).to eq(2)
    expect(revised.publication.payload["cutoff_at"]).to eq("2026-11-22T17:00:00+10:00")
    expect(first.calendar_period.publications.order(:schedule_version).pluck(:schedule_version)).to eq([ 1, 2 ])
  end

  it "refuses to rewrite a delivered calendar after its cutoff" do
    first = described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    first.publication.update!(delivery_status: "delivered", delivered_at: now)
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15))
    pay_period.update!(start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 30))

    expect do
      described_class.new(
        pay_period: pay_period.reload,
        source: source,
        actor: actor,
        now: Time.find_zone!("Pacific/Guam").local(2026, 10, 22, 17)
      ).call
    end.to raise_error(described_class::ConflictError, /cutoff has passed/)
  end

  context "with the October 16 rollout boundary" do
    let(:activation_date) { Date.new(2026, 10, 16) }

    it "publishes October 1–15 after its nominal cutoff with an explicit manual lock mode" do
      result = described_class.new(pay_period: pay_period, source: source, actor: actor,
        now: Time.find_zone!("Pacific/Guam").local(2026, 10, 24, 9)).call

      expect(result.publication.payload).to include(
        "lock_mode" => "manual", "cutoff_enforcement_starts_on" => "2026-10-16",
        "cutoff_at" => "2026-10-22T17:00:00+10:00")
      expect(source.reload.cutoff_enforcement_starts_on).to eq(Date.new(2026, 10, 16))
    end

    it "uses the October 31 regular payday for the first scheduled November 7 lock" do
      pay_period
      next_period = create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
        start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15))
      result = described_class.new(pay_period: next_period, source: source, actor: actor, now: now).call
      expect(result.publication.payload).to include("lock_mode" => "scheduled",
        "previous_regular_pay_date" => "2026-10-31", "cutoff_at" => "2026-11-07T17:00:00+10:00")
    end

    it "fails clearly without the October 1–15 regular run and never creates a dummy run" do
      next_period = create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
        start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15))
      expect do
        described_class.new(pay_period: next_period, source: source, actor: actor, now: now).call
      end.to raise_error(AirePayrollCalendar::Contract::Error, /adjacent previous regular payroll/)
      expect(company.pay_periods.count).to eq(2)
      expect(AirePayrollCalendarPublication.count).to eq(0)
    end
  end

  context "with an already delivered pre-rollout scheduled calendar" do
    let(:activation_date) { Date.new(2026, 10, 16) }
    let(:scheduled_period) do
      pay_period
      create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
        start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15))
    end
    let!(:legacy_calendar) do
      calendar = create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: scheduled_period)
      payload = source.connector.calendar_contract(scheduled_period).payload.except("lock_mode", "cutoff_enforcement_starts_on")
      create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar,
        payload: payload, delivery_status: "delivered", delivered_at: now,
        source_state: payload.merge("status" => "scheduled", "cutoff_state" => "upcoming"))
      calendar
    end

    it "does not create a revision just to add rollout metadata to retained scheduled evidence" do
      state = AirePayrollCalendar::Presenter.call(scheduled_period, now: now)
      expect(state).to include(needs_revision: false, cutoff_state: "upcoming", lock_mode: "scheduled")
      result = described_class.new(pay_period: scheduled_period, source: source, actor: actor, now: now).call
      expect(result.created).to be(false)
      expect(legacy_calendar.publications.count).to eq(1)
    end

    it "keeps a legitimate future policy revision compatible with AIRE's retained null activation" do
      publication = legacy_calendar.latest_publication
      # A legacy publication without weekly policy legitimately needs a revision.
      allow_any_instance_of(AirePayrollCalendarPublication).to receive(:payload).and_wrap_original do |method|
        value = method.call
        method.receiver.id == publication.id ? value.except("overtime_policy") : value
      end
      result = described_class.new(pay_period: scheduled_period, source: source, actor: actor, now: now).call
      expect(result.created).to be(true)
      expect(result.publication.payload).not_to have_key("lock_mode")
      expect(result.publication.payload).not_to have_key("cutoff_enforcement_starts_on")
      response = result.publication.payload.merge("external_pay_period_id" => legacy_calendar.external_pay_period_id,
        "lock_mode" => "scheduled", "cutoff_enforcement_starts_on" => nil)
      client = instance_double(TimeTracking::Client, publish_payroll_calendar_period: { "payroll_calendar_period" => response })
      delivery = AirePayrollCalendar::Delivery.new(publication_id: result.publication.id, now: now, client_factory: ->(*) { client }).call
      expect(delivery[:status]).to eq("delivered")
    end
  end

  it "rejects non-semimonthly periods and unrelated sources" do
    pay_period.update_column(:start_date, Date.new(2026, 10, 2))
    other_source = create(:time_tracking_source, source_type: "aire_services")

    expect do
      described_class.new(pay_period: pay_period, source: source, actor: actor, now: now).call
    end.to raise_error(AirePayrollCalendar::Contract::Error, /1st–15th/)
    expect do
      described_class.new(pay_period: pay_period, source: other_source, actor: actor, now: now).call
    end.to raise_error(described_class::Error, /does not belong/)
  end
end
