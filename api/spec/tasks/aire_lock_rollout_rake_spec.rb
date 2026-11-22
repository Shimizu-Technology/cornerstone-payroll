# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "aire_lock_rollout:configure" do
  let(:task) { Rake::Task["aire_lock_rollout:configure"] }
  let(:source) { create(:time_tracking_source, source_type: "aire_services") }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("aire_lock_rollout:configure")
    task.reenable
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("SOURCE_ID").and_return(source.id.to_s)
    allow(ENV).to receive(:fetch).with("STARTS_ON").and_return("2026-10-16")
    allow(ENV).to receive(:fetch).with("ACTOR").and_return("Release operator")
    allow(ENV).to receive(:fetch).with("REASON").and_return("Approved rollout")
  end

  it "scopes the operator to the task and records the rollout" do
    expect(AirePayrollCalendar::LockRollout).to receive(:new).and_wrap_original do |method, **attributes|
      expect(Current.actor).to eq(AuditActor.operator("Release operator"))
      method.call(**attributes)
    end

    expect { task.invoke }.to output(a_string_including("configured")).to_stdout
    expect(Current.actor).to be_nil
    expect(AuditLog.find_by!(action: "time_tracking_source#lock_rollout_gate_passed", record_id: source.id))
      .to have_attributes(actor_type: "operator", actor_name: "Release operator", user_id: nil)
  end

  it "clears the operator after a failed invocation" do
    allow(ENV).to receive(:fetch).with("REASON").and_return("short")
    expect { task.invoke }.to raise_error(AirePayrollCalendar::LockRollout::Error)

    expect(Current.actor).to be_nil
  end
end
