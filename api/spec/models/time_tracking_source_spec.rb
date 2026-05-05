# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTrackingSource do
  describe "validations" do
    it "requires an HTTP or HTTPS base URL with a host" do
      source = described_class.new(
        company: create(:company),
        name: "Bad Source",
        source_type: "custom",
        base_url: "example.com",
        shared_secret: "secret"
      )

      expect(source).not_to be_valid
      expect(source.errors[:base_url]).to include("must be an HTTP or HTTPS URL")
    end

    it "rejects URLs with embedded credentials" do
      source = described_class.new(
        company: create(:company),
        name: "Credentialed Source",
        source_type: "custom",
        base_url: "https://user:pass@example.com",
        shared_secret: "secret"
      )

      expect(source).not_to be_valid
      expect(source.errors[:base_url]).to include("must be an HTTP or HTTPS URL")
    end

    it "does not allow source_type to change after creation" do
      source = described_class.create!(
        company: create(:company),
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )

      source.source_type = "cornerstone_tax"

      expect(source).not_to be_valid
      expect(source.errors[:source_type]).to include("cannot be changed after creation")
    end
  end
end
