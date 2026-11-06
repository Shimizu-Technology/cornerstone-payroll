# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261014040000_bind_w2_readiness_to_current_inputs")

RSpec.describe BindW2ReadinessToCurrentInputs do
  after { W2FilingReadiness.reset_column_information }

  it "preserves legacy review identity, notes and the UTC instant without asserting current source readiness" do
    company = create(:company)
    actor = create(:user, company: company, organization: company.organization, role: "admin")
    stamp = Time.zone.parse("2026-03-10 18:35:20")
    original = W2FilingReadiness.create!(company: company, year: 2026, status: "filing_ready",
      marked_ready_at: stamp, marked_ready_by: actor, notes: "Reviewed legacy wages")

    ActiveRecord::Migration.suppress_messages do
      described_class.new.down
      described_class.new.up
    end
    W2FilingReadiness.reset_column_information
    migrated = W2FilingReadiness.find(original.id)
    review = migrated.attestation_history.fetch(0)

    expect(review).to include("marked_ready_by_id" => actor.id, "notes" => "Reviewed legacy wages", "legacy" => true, "source_fingerprint" => nil)
    expect(review.fetch("marked_ready_at")).to match(/(?:Z|[+-]\d{2}:\d{2})\z/)
    expect(Time.iso8601(review.fetch("marked_ready_at"))).to eq(stamp)
    expect(migrated.ready_fingerprint).to be_nil
    expect(migrated.current?("new-unverified-inputs")).to be(false)
    migrated.attestation_history = []
    expect(migrated).not_to be_valid
    expect(migrated.errors[:attestation_history]).to include("cannot rewrite previous reviews")
  end
end
