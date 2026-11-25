# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationJob do
  around { |example| Current.with_isolated_actor(nil) { example.run } }

  before do
    stub_const("AuditContextProbeJob", Class.new(described_class) do
      self.rls_mode = :system

      def perform(fail: false)
        AuditLog.record!(action: "audit_probe#performed", record_type: "probe")
        raise "job failed" if fail
      end
    end)
  end

  it "blocks job enqueue and inline execution while viewing" do
    Current.set(view_as_grant: ViewAsGrant.new) do
      expect { AuditContextProbeJob.perform_later }.to raise_error(ActiveRecord::ReadOnlyError)
      expect { AuditContextProbeJob.perform_now }.to raise_error(ActiveRecord::ReadOnlyError)
    end
    expect(AuditContextProbeJob).not_to have_been_enqueued
    expect(AuditLog.where(action: "audit_probe#performed")).to be_empty
    expect { AuditContextProbeJob.perform_later }.to have_enqueued_job(AuditContextProbeJob)
  end

  it "blocks the bulk enqueue API which skips job callbacks" do
    Current.set(view_as_grant: ViewAsGrant.new) do
      expect { ActiveJob.perform_all_later(AuditContextProbeJob.new) }.to raise_error(ActiveRecord::ReadOnlyError)
    end

    expect(AuditContextProbeJob).not_to have_been_enqueued
    expect { ActiveJob.perform_all_later(AuditContextProbeJob.new) }.to have_enqueued_job(AuditContextProbeJob)
  end

  it "blocks deferred jobs before registering work for after commit" do
    stub_const("DeferredAuditProbeJob", Class.new(AuditContextProbeJob) do
      self.enqueue_after_transaction_commit = true
    end)

    ApplicationRecord.transaction(requires_new: true) do
      Current.set(view_as_grant: ViewAsGrant.new) do
        expect { DeferredAuditProbeJob.perform_later }.to raise_error(ActiveRecord::ReadOnlyError)
        expect { ActiveJob.perform_all_later(DeferredAuditProbeJob.new) }.to raise_error(ActiveRecord::ReadOnlyError)
      end
    end
    expect(DeferredAuditProbeJob).not_to have_been_enqueued
  end

  it "keeps the job actor in a discard handler and restores the caller" do
    stub_const("DiscardAuditProbeJob", Class.new(described_class) do
      self.rls_mode = :system

      discard_on ArgumentError do
        AuditLog.record!(action: "audit_probe#discarded", record_type: "probe")
      end

      def perform
        raise ArgumentError, "discard probe"
      end
    end)
    staff = create(:user, role: :admin)
    caller_actor = AuditActor.for_user(staff)
    job = DiscardAuditProbeJob.new

    Current.set(actor: caller_actor, user: staff, request_id: "request-1", domain_audit_recorded: true) do
      job.perform_now
      expect(Current.actor).to eq(caller_actor)
      expect(Current.domain_audit_recorded).to be(true)
    end

    expect(AuditLog.find_by!(action: "audit_probe#discarded"))
      .to have_attributes(actor_type: "system_job", actor_id: job.job_id, user_id: nil, request_id: nil)
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
