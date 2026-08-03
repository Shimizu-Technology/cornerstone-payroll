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
end
