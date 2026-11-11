# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollCalendar::CutoffChange do
  include_context "aire cutoff change fixture"

  # AIRE confirms each change unless the example is about delivery.
  def change!(action:, actor: org_admin, cutoff_at: nil, reason: "Payday moved for the holiday", confirm: true, **options)
    described_class.new(pay_period: pay_period, action: action, cutoff_at: cutoff_at, reason: reason, actor: actor, **options).call.tap do |result|
      confirm_delivery!(result.publication) if confirm && !result.idempotent
    end
  end

  before { publish_delivered_calendar! }

  describe "permissions" do
    it "lets super admins and org admins change the lock time" do
      super_admin = create(:user, company: company, organization: company.organization, role: "super_admin")
      expect(change!(action: "change", cutoff_at: guam.local(2026, 10, 24, 12).iso8601, actor: super_admin).override.set_by).to eq(super_admin)
      expect(change!(action: "change", cutoff_at: guam.local(2026, 10, 25, 12).iso8601).override.set_by).to eq(org_admin)
    end

    %w[admin manager accountant employee client].each do |role|
      it "refuses #{role} users without recording anything" do
        user = create(:user, company: company, organization: company.organization, role: role)
        expect { change!(action: "lock_now", actor: user) }.to raise_error(described_class::Error) { |error|
          expect(error.status).to eq(:forbidden)
          expect(error.message).to eq("Only organization admins can change the time tracking lock time")
        }
        expect(AirePayrollCutoffOverride.count).to eq(0)
        expect(pay_period.aire_payroll_calendar_period.publications.count).to eq(1)
      end
    end

    it "refuses an org admin from another organization" do
      outsider = create(:user, role: "org_admin")
      expect { change!(action: "lock_now", actor: outsider) }.to raise_error(described_class::Error) { |error| expect(error.status).to eq(:forbidden) }
    end

    it "accepts an AIRE owner or admin through the authenticated source and refuses AIRE managers" do
      result = described_class.new(pay_period: pay_period, action: "lock_now", reason: "Payroll is ready early",
        source_actor: aire_actor(role: "owner", name: "Leon"), source: source, request_id: SecureRandom.uuid).call
      expect(result.override).to have_attributes(requested_via: "aire_services", set_by: nil, set_by_name: "Leon")

      manager = described_class.new(pay_period: create_next_period!, action: "lock_now", reason: "Try it",
        source_actor: aire_actor(role: "manager"), source: source, request_id: SecureRandom.uuid)
      expect { manager.call }.to raise_error(described_class::Error, "Only AIRE owners and admins can change the lock time")
    end

    it "refuses an AIRE request authenticated by a different source" do
      other = create(:time_tracking_source, company: company, source_type: "aire_services", active: false)
      request = described_class.new(pay_period: pay_period, action: "lock_now", reason: "Ready",
        source_actor: aire_actor, source: other, request_id: SecureRandom.uuid)
      expect { request.call }.to raise_error(described_class::Error) { |error| expect(error.status).to eq(:forbidden) }
    end
  end

  describe "changing the lock time" do
    it "records the override, audits it, and republishes the effective cutoff to AIRE" do
      result = change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00")

      expect(result.override).to have_attributes(
        action: "change", cutoff_at: guam.local(2026, 10, 25, 10, 30), previous_cutoff_at: policy_cutoff,
        policy_cutoff_at: policy_cutoff, reason: "Payday moved for the holiday", requested_via: "cornerstone_payroll"
      )
      expect(result.publication.schedule_version).to eq(2)
      expect(result.publication.payload).to include(
        "cutoff_at" => "2026-10-25T10:30:00+10:00",
        "cutoff_source" => "override",
        "policy_cutoff_at" => "2026-10-22T17:00:00+10:00",
        "cutoff_rule" => "after_previous_regular_payday",
        "cutoff_days" => 7,
        "previous_regular_pay_date" => "2026-10-15",
        "cutoff_override" => {
          "override_id" => result.override.override_id,
          "action" => "change",
          "reason" => "Payday moved for the holiday",
          "set_at" => "2026-10-17T09:00:00+10:00",
          "set_by" => { "name" => "Chels", "system" => "cornerstone_payroll", "role" => "org_admin" },
          "previous_cutoff_at" => "2026-10-22T17:00:00+10:00"
        }
      )
      expect(AirePayrollCalendarPublication).to have_received(:dispatch_one!).with(result.publication.id, now: Time.current)
      audit = AuditLog.find_by!(action: "aire_payroll_calendar#cutoff_changed")
      expect(audit).to have_attributes(user_id: org_admin.id, company_id: company.id, record_id: result.override.id)
      expect(audit.metadata).to include("change" => "change", "previous_cutoff_at" => policy_cutoff.iso8601,
        "reason" => "Payday moved for the holiday", "schedule_version" => 2)
    end

    it "keeps the previous override as history and reports it as the previous value" do
      first = change!(action: "change", cutoff_at: "2026-10-20T12:00:00+10:00").override
      second = change!(action: "change", cutoff_at: "2026-10-26T12:00:00+10:00", reason: "Moved again").override

      expect(second.previous_cutoff_at).to eq(first.cutoff_at)
      expect(AirePayrollCutoffOverride.current_for(pay_period)).to eq(second)
      expect { first.update!(reason: "edited") }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { AirePayrollCutoffOverride.where(id: first.id).update_all(reason: "edited") }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    [
      [ "2026-10-15T23:59:00+10:00", "Choose a time after the period ends" ],
      [ "2026-10-30T00:00:00+10:00", "Choose a time at least two days before payday" ],
      [ "2026-10-17T08:00:00+10:00", "Choose a time at least 15 minutes from now" ],
      [ "2026-10-17T09:14:00+10:00", "Choose a time at least 15 minutes from now" ],
      [ "2026-10-22T17:00:00+10:00", "That is already the lock time" ],
      [ "2026-10-25T10:30:00", "Choose a lock time with a time zone" ]
    ].each do |cutoff_at, message|
      it "rejects #{cutoff_at} (#{message})" do
        expect { change!(action: "change", cutoff_at: cutoff_at) }.to raise_error(described_class::Error, message)
        expect(AirePayrollCutoffOverride.count).to eq(0)
      end
    end

    it "accepts the boundary instants and drops seconds" do
      travel_to(guam.local(2026, 10, 15, 12))
      expect(change!(action: "change", cutoff_at: "2026-10-16T00:00:00+10:00").override.cutoff_at).to eq(guam.local(2026, 10, 16))
      expect(change!(action: "change", cutoff_at: "2026-10-29T23:59:42+10:00").override.cutoff_at).to eq(guam.local(2026, 10, 29, 23, 59))
    end

    it "accepts a time exactly 15 minutes ahead" do
      travel_to(guam.local(2026, 10, 17, 9, 0, 20))
      expect(change!(action: "change", cutoff_at: "2026-10-17T09:16:00+10:00").override.cutoff_at).to eq(guam.local(2026, 10, 17, 9, 16))
      expect(described_class.bounds(pay_period)[:earliest_at]).to eq(guam.local(2026, 10, 17, 9, 16))
    end

    it "refuses every change once AIRE's lock is under 15 minutes away" do
      travel_to(policy_cutoff - 14.minutes)
      %w[lock_now change].each do |action|
        expect { change!(action: action, cutoff_at: "2026-10-25T10:30:00+10:00") }.to raise_error(described_class::Error) { |error|
          expect(error.status).to eq(:conflict)
          expect(error.message).to eq("AIRE locks this period in under 15 minutes, so its lock time can no longer change")
        }
      end
      expect(AirePayrollCutoffOverride.count).to eq(0)
    end

    it "refuses a change after AIRE's batch was imported, even before its event arrives" do
      create(:time_tracking_import, :finalized_aire_batch, pay_period: pay_period, time_tracking_source: source)
      expect { change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00") }.to raise_error(described_class::Error) { |error|
        expect(error.status).to eq(:conflict)
        expect(error.message).to eq("Time tracking already locked this period")
      }
      expect(pay_period.aire_payroll_calendar_period.publications.count).to eq(1)
    end

    it "returns a clean conflict when a concurrent publication aborts the statement" do
      allow_any_instance_of(AirePayrollCalendarPublication).to receive(:save!).and_wrap_original do |original, *args, **kwargs|
        # Leaves PostgreSQL's transaction aborted, as a real unique-key race does.
        begin
          ActiveRecord::Base.connection.execute("SELECT 1/0")
        rescue ActiveRecord::StatementInvalid
          nil
        end
        raise ActiveRecord::RecordNotUnique, "duplicate key value violates unique constraint"
      end

      expect { change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00", confirm: false) }.to raise_error(described_class::Error) { |error|
        expect(error.status).to eq(:conflict)
        expect(error.message).to include("won the concurrent update")
      }
      expect(AirePayrollCutoffOverride.count).to eq(0)
    end

    it "requires a reason" do
      expect { change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00", reason: "  ") }
        .to raise_error(described_class::Error, "Enter a reason for the change")
      expect { change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00", reason: "x" * 501) }
        .to raise_error(described_class::Error, /under 500/)
    end
  end

  describe "lock now" do
    it "sets the cutoff to the current second and publishes a deliverable lock-now revision" do
      travel_to(guam.local(2026, 10, 17, 9, 15, 30) + 0.4.seconds)
      result = change!(action: "lock_now", reason: "All approvals are in")

      expect(result.override.cutoff_at).to eq(guam.local(2026, 10, 17, 9, 15, 30))
      expect(result.publication.payload).to include("cutoff_at" => "2026-10-17T09:15:30+10:00", "cutoff_source" => "override")
      expect(result.publication.payload.dig("cutoff_override", "action")).to eq("lock_now")
      expect(AirePayrollCalendar::Publisher.lock_now_deliverable?(result.publication.payload, 29.minutes.from_now)).to be(true)
      expect(AirePayrollCalendar::Publisher.lock_now_deliverable?(result.publication.payload, 31.minutes.from_now)).to be(false)
    end

    it "waits until the period's last day is over in Guam" do
      travel_to(guam.local(2026, 10, 15, 23, 59))
      expect { change!(action: "lock_now") }.to raise_error(described_class::Error, "Lock now is available after the period ends (Oct 16)")
    end

    it "refuses periods whose lock time already passed or that AIRE already locked" do
      travel_to(policy_cutoff + 1.minute)
      expect { change!(action: "lock_now") }.to raise_error(described_class::Error, "This period's lock time has already passed")

      travel_to(guam.local(2026, 10, 17, 9))
      calendar = pay_period.aire_payroll_calendar_period
      allow(calendar.payroll_events).to receive(:exists?).and_return(true)
      allow_any_instance_of(PayPeriod).to receive(:aire_payroll_calendar_period).and_return(calendar)
      expect { change!(action: "lock_now") }.to raise_error(described_class::Error, "Time tracking already locked this period")
    end
  end

  describe "delivery to AIRE" do
    it "waits for a change still on its way, then lets a new change supersede one AIRE refused" do
      pending_change = change!(action: "change", cutoff_at: "2026-10-17T09:15:00+10:00", confirm: false).publication

      expect { change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00") }.to raise_error(described_class::Error) { |error|
        expect(error.status).to eq(:conflict)
        expect(error.message).to eq("The previous lock-time change is still being delivered to AIRE. Try again once AIRE confirms it.")
      }
      expect(AirePayrollCalendar::Presenter.call(pay_period.reload)).to include(
        applied_cutoff_at: "2026-10-22T17:00:00+10:00",
        cutoff_delivery: include(state: "pending", schedule_version: 2, cutoff_at: "2026-10-17T09:15:00+10:00")
      )

      # Delivery reached AIRE after 9:15, and AIRE refused it.
      travel_to(guam.local(2026, 10, 17, 9, 20))
      reject_delivery!(pending_change)
      state = AirePayrollCalendar::Presenter.call(pay_period.reload)
      expect(state[:cutoff_delivery]).to include(state: "rejected", error: "cutoff_at must be in the future when published")
      expect(state[:cutoff_control]).to include(available: true, unavailable_reason: nil)

      result = change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00", reason: "Try again", confirm: false)
      expect(result.publication.schedule_version).to eq(3)
      expect(result.override.previous_cutoff_at).to eq(policy_cutoff)
      expect(result.publication.payload.dig("cutoff_override", "previous_cutoff_at")).to eq("2026-10-22T17:00:00+10:00")
    end

    it "lets a repeated reset supersede a refused reset with the same contract" do
      change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00")
      refused = change!(action: "reset", reason: "Back to normal", confirm: false).publication
      reject_delivery!(refused, "Payroll calendar periods cannot overlap", status: 409)

      result = change!(action: "reset", reason: "Back to normal again", confirm: false)
      expect(result.publication.schedule_version).to eq(refused.schedule_version + 1)
      expect(result.publication.payload).to include("cutoff_source" => "policy", "cutoff_at" => "2026-10-22T17:00:00+10:00")
    end

    it "stops delivering the refused version it replaces" do
      refused = change!(action: "change", cutoff_at: "2026-10-17T09:15:00+10:00", confirm: false).publication
      # A 409 for a time still ahead keeps retrying, so it could still reach AIRE.
      reject_delivery!(refused, "The payroll calendar changed concurrently", status: 409)
      refused.update_columns(next_delivery_attempt_at: 1.minute.from_now)

      replacement = change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00", reason: "Try again", confirm: false).publication
      expect(refused.reload).to have_attributes(next_delivery_attempt_at: nil, delivery_enqueued_until: nil,
        last_error: "Superseded by schedule version #{replacement.schedule_version}")
      expect(AirePayrollCalendarPublication.due_for_delivery(2.minutes.from_now)).to contain_exactly(replacement)
    end

    it "lets a new change supersede one whose only delivery came after its time and lost the response" do
      expired = change!(action: "change", cutoff_at: "2026-10-17T09:15:00+10:00", confirm: false).publication
      # The job ran late, and AIRE's answer never came back.
      client = instance_double(TimeTracking::Client)
      allow(client).to receive(:publish_payroll_calendar_period).and_raise(TimeTracking::Client::Error, "Could not securely reach AIRE")
      travel_to(guam.local(2026, 10, 17, 9, 20))
      AirePayrollCalendar::Delivery.new(publication_id: expired.id, client_factory: ->(*) { client }).call
      expect(expired.reload).to have_attributes(delivery_status: "failed", delivery_attempts: 1, last_response_status: nil, next_delivery_attempt_at: nil)

      state = AirePayrollCalendar::Presenter.call(pay_period.reload)
      expect(state[:cutoff_delivery]).to include(state: "expired", schedule_version: 2, cutoff_at: "2026-10-17T09:15:00+10:00")
      expect(state[:cutoff_control]).to include(available: true, unavailable_reason: nil)

      result = change!(action: "change", cutoff_at: "2026-10-22T17:00:00+10:00", reason: "Keep the default", confirm: false)
      expect(result.publication.schedule_version).to eq(3)
      expect(result.override.previous_cutoff_at).to eq(policy_cutoff)
      expect(expired.reload.last_error).to eq("Superseded by schedule version 3")
    end

    it "drops the delivery note once time tracking locked the period" do
      refused = change!(action: "change", cutoff_at: "2026-10-17T09:15:00+10:00", confirm: false).publication
      reject_delivery!(refused)
      expect(AirePayrollCalendar::Presenter.call(pay_period.reload)[:cutoff_delivery]).to include(state: "rejected")

      create(:time_tracking_import, :finalized_aire_batch, pay_period: pay_period, time_tracking_source: source)
      expect(AirePayrollCalendar::Presenter.call(pay_period.reload)[:cutoff_delivery]).to be_nil
    end

    it "locks the pay period, then the source, before it reads what AIRE applied" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
      begin
        change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00", confirm: false)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      pay_period_lock = statements.index { |sql| sql.match?(/FROM "pay_periods".*FOR UPDATE/m) }
      source_lock = statements.index { |sql| sql.match?(/FROM "time_tracking_sources".*FOR UPDATE/m) }
      first_publication_read = statements.index { |sql| sql.include?(%(FROM "aire_payroll_calendar_publications")) }
      expect([ pay_period_lock, source_lock, first_publication_read ]).to all(be_present)
      expect(pay_period_lock).to be < source_lock
      expect(source_lock).to be < first_publication_read
    end

    it "judges a passed lock time by the version AIRE applied" do
      change!(action: "change", cutoff_at: "2026-10-17T09:30:00+10:00")
      travel_to(guam.local(2026, 10, 17, 9, 31))
      expect { change!(action: "lock_now") }.to raise_error(described_class::Error, "This period's lock time has already passed")
    end
  end

  describe "reset" do
    it "returns to the policy cutoff and publishes a plain policy revision" do
      change!(action: "change", cutoff_at: "2026-10-20T12:00:00+10:00")
      result = change!(action: "reset", reason: "Back to normal")

      expect(result.override).to have_attributes(action: "reset", cutoff_at: policy_cutoff, previous_cutoff_at: guam.local(2026, 10, 20, 12))
      expect(AirePayrollCutoffOverride.current_for(pay_period)).to be_nil
      expect(result.publication.payload).to include("cutoff_at" => "2026-10-22T17:00:00+10:00", "cutoff_source" => "policy")
      expect(result.publication.payload).not_to include("cutoff_override", "policy_cutoff_at")
    end

    it "refuses a reset when the default lock is under 15 minutes away" do
      change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00")
      travel_to(policy_cutoff - 10.minutes)
      expect { change!(action: "reset") }.to raise_error(described_class::Error, "The default lock time is less than 15 minutes away. Use Lock now instead.")
    end

    it "refuses a reset when nothing was changed" do
      expect { change!(action: "reset") }.to raise_error(described_class::Error, "This period already uses the default lock time")
    end
  end

  describe "idempotent AIRE requests" do
    let(:request_id) { SecureRandom.uuid }

    def aire_change(reason: "Ready early")
      described_class.new(pay_period: pay_period, action: "lock_now", reason: reason, source_actor: aire_actor,
        source: source, request_id: request_id).call
    end

    it "replays the same request without another override or publication" do
      first = aire_change
      replay = aire_change

      expect(replay.idempotent).to be(true)
      expect(replay.override).to eq(first.override)
      expect(replay.publication).to eq(first.publication)
      expect(AirePayrollCutoffOverride.count).to eq(1)
      expect { aire_change(reason: "Different") }.to raise_error(described_class::Error) { |error| expect(error.status).to eq(:conflict) }
    end

    it "treats the same request ID with a different time as a conflict" do
      first = change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00", request_id: request_id)
      replay = change!(action: "change", cutoff_at: "2026-10-25T10:30:00+10:00", request_id: request_id)
      expect(replay).to have_attributes(idempotent: true, override: first.override)

      expect { change!(action: "change", cutoff_at: "2026-10-26T10:30:00+10:00", request_id: request_id) }
        .to raise_error(described_class::Error, "This request ID was already used for a different lock-time change") { |error|
          expect(error.status).to eq(:conflict)
        }
      expect(AirePayrollCutoffOverride.count).to eq(1)
    end
  end

  def create_next_period!
    create(:pay_period, company: company, company_pay_schedule: schedule, company_workweek: workweek,
      start_date: Date.new(2026, 10, 16), end_date: Date.new(2026, 10, 31), pay_date: Date.new(2026, 11, 15)).tap do |period|
      AirePayrollCalendar::Publisher.new(pay_period: period, source: source, actor: org_admin).call
    end
  end
end
