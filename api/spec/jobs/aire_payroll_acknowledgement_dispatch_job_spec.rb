# frozen_string_literal: true

require "rails_helper"

RSpec.describe AirePayrollAcknowledgementDispatchJob, type: :job do
  it "retries both batch-level and entry-level AIRE outboxes" do
    expect(AirePayrollAcknowledgement).to receive(:dispatch_pending!)
    expect(AirePayrollEntryAcknowledgement).to receive(:dispatch_pending!)

    described_class.perform_now
  end
end
