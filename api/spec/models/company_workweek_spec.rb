# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyWorkweek do
  it "keeps a legacy Sunday workweek visibly unconfirmed" do
    workweek = described_class.create!(
      company: create(:company),
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )

    expect(workweek).not_to be_confirmed
  end


  it "rejects new non-midnight boundaries while time evidence is date-only" do
    workweek = described_class.new(
      company: create(:company),
      starts_on_weekday: 1,
      starts_at_minutes: 480,
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )

    expect(workweek).not_to be_valid
    expect(workweek.errors[:starts_at_minutes]).to include(/must be midnight/)
  end

  it "allows an existing legacy non-midnight record to be closed during replacement" do
    workweek = described_class.create!(
      company: create(:company),
      starts_on_weekday: 1,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )
    workweek.update_column(:starts_at_minutes, 480)

    expect { workweek.update!(ends_on: Date.new(2026, 6, 30)) }.not_to raise_error
  end
end
