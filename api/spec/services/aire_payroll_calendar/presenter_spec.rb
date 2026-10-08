# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::Presenter do
  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let(:actor) { create(:user, company: company) }
  let!(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
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

  it "uses the capability-selected source for both metadata and its contract" do
    unsupported = create(:time_tracking_source, company: company, name: "Legacy summary", active: false)
    allow(company.time_tracking_sources).to receive(:active).and_return([ unsupported, source ])
    pay_period.company = company
    state = described_class.call(pay_period, now: Time.find_zone!("Pacific/Guam").local(2026, 10, 1, 9))
    expect(state).to include(source_id: source.id, eligible: true, can_publish: true)
    expect(state[:cutoff_at]).to eq("2026-10-22T17:00:00+10:00")
  end

  it "shows a missed unpublished cutoff as unavailable instead of offering a broken publish action" do
    state = described_class.call(
      pay_period,
      now: Time.find_zone!("Pacific/Guam").local(2026, 10, 22, 17)
    )

    expect(state).to include(
      eligible: false,
      can_publish: false,
      cutoff_state: "cutoff_due"
    )
    expect(state.fetch(:eligibility_error)).to include("passed before it was published")
    expect(state.fetch(:eligibility_code)).to eq("cutoff_passed")
  end

  it "explains when confirmed AIRE setup starts after an older pay period" do
    schedule.update!(effective_on: Date.new(2026, 9, 16))
    legacy_schedule = CompanyPaySchedule.create!(
      company: company,
      frequency: "semimonthly",
      period_rule: "manual",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 9, 15)
    )
    pay_period.update_columns(
      start_date: Date.new(2026, 8, 16),
      end_date: Date.new(2026, 8, 31),
      pay_date: Date.new(2026, 9, 15),
      company_pay_schedule_id: legacy_schedule.id
    )

    state = described_class.call(pay_period, now: Time.find_zone!("Pacific/Guam").local(2026, 9, 1, 9))

    expect(state).to include(
      eligible: false,
      can_publish: false,
      eligibility_code: "pay_schedule_not_effective"
    )
    expect(state.fetch(:eligibility_error)).to include("takes effect on September 16, 2026")
  end

  it "rejects an attached schedule that no longer covers the pay period" do
    schedule.update!(effective_on: Date.new(2026, 10, 16))

    state = described_class.call(pay_period, now: Time.find_zone!("Pacific/Guam").local(2026, 10, 1, 9))

    expect(state).to include(
      eligible: false,
      can_publish: false,
      eligibility_code: "pay_schedule_not_effective"
    )
    expect(state.fetch(:eligibility_error)).to include("takes effect on October 16, 2026")
  end

  it "does not offer a schedule revision after the delivered cutoff has passed" do
    calendar_period = create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: pay_period
    )
    create(
      :aire_payroll_calendar_publication,
      aire_payroll_calendar_period: calendar_period,
      delivery_status: "delivered",
      delivered_at: Time.find_zone!("Pacific/Guam").local(2026, 10, 17, 17)
    )
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15))
    pay_period.update!(start_date: Date.new(2026, 11, 1), end_date: Date.new(2026, 11, 15), pay_date: Date.new(2026, 11, 30))

    state = described_class.call(
      pay_period,
      now: Time.find_zone!("Pacific/Guam").local(2026, 10, 20, 9)
    )

    expect(state).to include(
      eligible: true,
      needs_revision: true,
      can_publish: false,
      cutoff_state: "schedule_changed"
    )
  end

  it "keeps the calendar period tied to its original source when that source is inactive" do
    source.update!(active: false)
    replacement = create(:time_tracking_source, company: company, source_type: "aire_services", name: "Replacement AIRE")
    create(
      :aire_payroll_calendar_period,
      company: company,
      time_tracking_source: source,
      pay_period: pay_period
    )

    state = described_class.call(pay_period, now: Time.find_zone!("Pacific/Guam").local(2026, 10, 1, 9))

    expect(state).to include(source_id: source.id, source_name: source.name)
    expect(state.fetch(:source_id)).not_to eq(replacement.id)
  end

  describe "delivered calendar cutoff progression" do
    let(:cutoff) { Time.find_zone!("Pacific/Guam").local(2026, 10, 22, 17) }
    let!(:calendar_period) { create(:aire_payroll_calendar_period, company: company, time_tracking_source: source, pay_period: pay_period) }
    let(:cached_state) { "upcoming" }
    let!(:publication) do
      create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar_period,
        payload: source.connector.calendar_contract(pay_period).payload, delivery_status: "delivered", delivered_at: cutoff - 1.day,
        source_state: { "cutoff_state" => cached_state })
    end

    [ nil, "", "upcoming", "scheduled" ].each do |captured|
      context "with captured #{captured.inspect} state" do
        let(:cached_state) { captured }

        it "stays upcoming before the exact cutoff" do
          expected = captured.presence || "scheduled"
          expect(described_class.call(pay_period, now: cutoff - 1.second)[:cutoff_state]).to eq(expected)
        end

        [ 0, 1 ].each do |offset|
          it "is due #{offset.zero? ? 'at' : 'after'} cutoff without changing the delivery snapshot" do
            original = publication.source_state.deep_dup
            expect(described_class.call(pay_period, now: cutoff + offset)[:cutoff_state]).to eq("cutoff_due")
            expect(publication.reload.source_state).to eq(original)
          end
        end
      end
    end

    %w[finalized attention_required due cutoff_due].each do |captured|
      context "with captured #{captured} state" do
        let(:cached_state) { captured }

        it "preserves the source state at and after cutoff" do
          [ cutoff, cutoff + 1.second ].each do |now|
            expect(described_class.call(pay_period, now: now)[:cutoff_state]).to eq(captured)
          end
        end
      end
    end

    %w[failed pending].each do |delivery_status|
      it "preserves #{delivery_status} publication precedence after cutoff" do
        other = create(:aire_payroll_calendar_publication, aire_payroll_calendar_period: calendar_period,
          schedule_version: 2, delivery_status: delivery_status, source_state: { "cutoff_state" => "upcoming" },
          payload: source.connector.calendar_contract(pay_period).payload)
        expected = delivery_status == "failed" ? "publication_failed" : "publishing"
        expect(described_class.call(pay_period.reload, now: cutoff + 1.second)[:cutoff_state]).to eq(expected)
        expect(other.reload.delivery_status).to eq(delivery_status)
      end
    end

    { "verified" => "batch_verified", "rejected" => "batch_rejected", "failed" => "batch_verification_failed", "pending" => "batch_verifying" }.each do |verification, expected|
      it "keeps #{verification} event precedence over the elapsed calendar" do
        AirePayrollEvent.create!(aire_payroll_calendar_period: calendar_period, aire_payroll_calendar_publication: publication,
          time_tracking_source: source, event_id: SecureRandom.uuid, event_type: AirePayrollEvent::EVENT_TYPE,
          occurred_at: cutoff, payroll_batch_id: SecureRandom.uuid, payroll_batch_checksum: "a" * 64,
          payload_checksum: "b" * 64, verification_status: verification,
          payload: { "payroll_batch" => { "summary" => {}, "issues" => {} } })
        expect(described_class.call(pay_period, now: cutoff + 1.second)[:cutoff_state]).to eq(expected)
      end
    end
  end
end
