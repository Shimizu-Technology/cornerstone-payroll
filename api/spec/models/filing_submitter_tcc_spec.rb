# frozen_string_literal: true

require "rails_helper"

RSpec.describe FilingSubmitter do
  it "allows blank TCC, validates five alphanumeric characters, and keeps it out of SSA requirements" do
    profile = described_class.new(organization: create(:organization))
    expect(profile).to be_valid
    expect(profile.missing_fields).not_to include(:tcc)
    [ "ABCDE", "a12B3" ].each { |value| profile.tcc = value; expect(profile).to be_valid }
    [ "ABC", "ABCDEF", "A!234" ].each { |value| profile.tcc = value; expect(profile).not_to be_valid }
  end
end
