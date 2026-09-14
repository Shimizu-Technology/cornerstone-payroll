# frozen_string_literal: true

require "rails_helper"

RSpec.describe QueueDurabilityProbeJob, type: :job do
  let!(:probe) do
    OperationalQueueProbe.create!(
      probe_id: SecureRandom.uuid,
      expires_at: 1.hour.from_now
    )
  end

  it "records one effect and preserves it across an idempotent replay" do
    described_class.perform_now(probe.probe_id)
    first_completion = probe.reload.completed_at

    described_class.perform_now(probe.probe_id)

    expect(probe.reload).to have_attributes(
      attempt_count: 2,
      effect_count: 1,
      completed_at: first_completion
    )
    expect(probe).to be_passed
  end

  it "rejects an unknown probe instead of creating an unattributed record" do
    expect { described_class.perform_now(SecureRandom.uuid) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
