# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTrackingLockRolloutSelection do
  let(:source) { create(:time_tracking_source, source_type: "aire_services") }
  let(:attributes) { { time_tracking_source: source, starts_on: "2026-11-01", actor: "Reviewed operator", reason: "Approved later initial Stage 2 rollout" } }

  it "retains the original column and refuses SQL updates, deletion and truncation of the appended decision" do
    selection = described_class.create!(attributes)
    expect(source.reload[:cutoff_enforcement_starts_on]).to eq(Date.new(2026, 10, 16))
    expect(source.cutoff_enforcement_starts_on).to eq(Date.new(2026, 11, 1))
    [ -> { described_class.where(id: selection.id).update_all(starts_on: "2026-11-16") },
      -> { selection.delete },
      -> { described_class.connection.execute("TRUNCATE time_tracking_lock_rollout_selections") } ].each do |mutation|
      expect { described_class.transaction(requires_new: true) { mutation.call } }
        .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    end
  end

  it "rejects an earlier initial selection at the database boundary" do
    expect { described_class.transaction(requires_new: true) { described_class.create!(attributes.merge(starts_on: "2026-10-01")) } }
      .to raise_error(ActiveRecord::StatementInvalid, /must be later/)
  end

  it "rejects selection after the existing explicit rollout gate" do
    AirePayrollCalendar::LockRollout.new(source: source, starts_on: "2026-10-16", actor: "Reviewed operator", reason: "Approved original October rollout").configure!
    expect { described_class.transaction(requires_new: true) { described_class.create!(attributes) } }
      .to raise_error(ActiveRecord::StatementInvalid, /unused, ungated/)
  end

  it "rejects selection while any source calendar already exists" do
    period = create(:pay_period, company: source.company)
    create(:aire_payroll_calendar_period, company: source.company, time_tracking_source: source, pay_period: period)
    expect { described_class.transaction(requires_new: true) { described_class.create!(attributes) } }
      .to raise_error(ActiveRecord::StatementInvalid, /unused, ungated/)
  end
end
