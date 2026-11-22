# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationJob do
  before do
    stub_const("AuditContextProbeJob", Class.new(described_class) do
      def perform(fail: false)
        AuditLog.record!(action: "audit_probe#performed", record_type: "probe")
        raise "job failed" if fail
      end
    end)
  end

  it "isolates consecutive inline jobs on one thread, even when a job raises" do
    staff = create(:user, role: :admin)
    caller_actor = AuditActor.for_user(staff)
    first = AuditContextProbeJob.new(fail: true)
    second = AuditContextProbeJob.new

    Current.set(actor: caller_actor, user: staff, request_id: "request-1") do
      expect { first.perform_now }.to raise_error("job failed")
      expect(Current.actor).to eq(caller_actor)
      expect(Current.domain_audit_recorded).to be_nil
    end

    expect(Current.actor).to be_nil
    second.perform_now
    expect(Current.actor).to be_nil
    expect(Current.domain_audit_recorded).to be_nil
    expect(AuditLog.where(action: "audit_probe#performed").oldest_first).to match([
      have_attributes(actor_type: "system_job", actor_id: first.job_id, user_id: nil, request_id: nil),
      have_attributes(actor_type: "system_job", actor_id: second.job_id, user_id: nil, request_id: nil)
    ])
  end
end
