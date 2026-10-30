# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConnectedPayrollJob do
  include ActiveJob::TestHelper

  around do |example|
    previous = ENV["CONNECTED_PAYROLL_MODE"]
    ENV["CONNECTED_PAYROLL_MODE"] = "paused"
    example.run
  ensure
    ENV["CONNECTED_PAYROLL_MODE"] = previous
    clear_enqueued_jobs
  end

  [ AireManualAllocationSyncJob, AirePayrollAcknowledgementDispatchJob,
    AirePayrollCalendarDeliveryJob, AirePayrollCalendarDispatchJob,
    AirePayrollCalendarSourceRefreshJob, AirePayrollEntryStatusSyncJob,
    AirePayrollEventVerificationJob, AirePayrollStatusSyncJob,
    TimeTrackingCorrectionReceiptJob ].each do |job_class|
    it "defers #{job_class} before looking up records and preserves exception retry budgets" do
      job = job_class.new(*([ AirePayrollAcknowledgementDispatchJob, AirePayrollCalendarDispatchJob ].include?(job_class) ? [] : [ -1 ]))
      job.exception_executions = { "TimeTracking::Client::Error" => 3 }
      expect(TimeTracking::Client).not_to receive(:new)
      if job.arguments.any?
        expect { job.perform_now }.to have_enqueued_job(job_class).at(a_value > Time.current)
        expect(enqueued_jobs.last["exception_executions"]).to eq("TimeTracking::Client::Error" => 3)
      else
        expect { job.perform_now }.not_to have_enqueued_job(job_class)
      end
    end
  end

  it "executes deferred work after resuming" do
    expect(AirePayrollCalendarPublication).to receive(:dispatch_due!).once
    expect(AirePayrollEvent).to receive(:dispatch_due!).once
    job = AirePayrollCalendarDispatchJob.new
    job.perform_now
    ENV["CONNECTED_PAYROLL_MODE"] = "enabled"
    job.perform_now
  end
end
