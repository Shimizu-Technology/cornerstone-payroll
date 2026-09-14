# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperationalQueueProbe, type: :model do
  subject(:probe) do
    described_class.new(
      probe_id: SecureRandom.uuid,
      expires_at: 1.hour.from_now
    )
  end

  it "accepts a new pending probe" do
    expect(probe).to be_valid
    expect(probe).not_to be_passed
  end

  it "requires a canonical UUID without line breaks" do
    probe.probe_id = "#{SecureRandom.uuid}\n"

    expect(probe).not_to be_valid
    expect(probe.errors[:probe_id]).to be_present
  end

  it "requires the completion marker and effect count to agree" do
    probe.effect_count = 1

    expect(probe).not_to be_valid
    expect(probe.errors[:completed_at]).to include("must be present exactly when the probe effect is recorded")
  end

  it "passes only after at least one attempt records the single effect" do
    probe.attempt_count = 1
    probe.effect_count = 1
    probe.completed_at = Time.current

    expect(probe).to be_passed
  end
end
