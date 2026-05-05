# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::EmployeeMatcher do
  describe "#match" do
    it "matches by email without loading the full employee table" do
      company = create(:company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      employee = create(:employee, company: company, email: "worker@example.com")

      match = described_class.new(company: company, source: source).match(
        "source_user_id" => "source-1",
        "email" => " Worker@Example.com ",
        "display_name" => "Different Name"
      )

      expect(match).to include(employee_id: employee.id, match_method: "email", match_score: 1.0)
    end

    it "limits fuzzy candidates when no direct mapping or email match exists" do
      company = create(:company)
      source = TimeTrackingSource.create!(
        company: company,
        name: "AIRE",
        source_type: "aire_services",
        base_url: "https://aire.example.com",
        shared_secret: "secret"
      )
      create(:employee, company: company, first_name: "Alex", last_name: "Worker", email: "alex@example.com")

      matcher = described_class.new(company: company, source: source)

      expect(matcher).to receive(:fuzzy_candidates).with("Alex Worker").and_call_original
      match = matcher.match("source_user_id" => "source-2", "display_name" => "Alex Worker")

      expect(match).to include(match_method: "name")
    end
  end
end
