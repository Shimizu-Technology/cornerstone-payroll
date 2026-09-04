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

    it "prefers the permanent AIRE UUID when the numeric source ID changes" do
      company = create(:company)
      source = create(:time_tracking_source, company: company, source_type: "aire_services")
      employee = create(:employee, company: company, email: "permanent@example.com")
      source_uuid = SecureRandom.uuid
      TimeTrackingEmployeeMapping.create!(
        company: company,
        time_tracking_source: source,
        employee: employee,
        source_user_id: "old-id",
        source_user_uuid: source_uuid
      )

      match = described_class.new(company: company, source: source).match(
        "source_user_id" => "new-id",
        "source_user_uuid" => source_uuid,
        "email" => "changed@example.com"
      )

      expect(match).to include(employee_id: employee.id, match_method: "saved_mapping", match_score: 1.0)
    end

    it "blocks a reused numeric source ID when its permanent UUID disagrees" do
      company = create(:company)
      source = create(:time_tracking_source, company: company, source_type: "aire_services")
      employee = create(:employee, company: company)
      TimeTrackingEmployeeMapping.create!(
        company: company,
        time_tracking_source: source,
        employee: employee,
        source_user_id: "reused-id",
        source_user_uuid: SecureRandom.uuid
      )

      expect do
        described_class.new(company: company, source: source).match(
          "source_user_id" => "reused-id",
          "source_user_uuid" => SecureRandom.uuid,
          "email" => employee.email
        )
      end.to raise_error(TimeTrackingEmployeeMapping::IdentityConflict, /different permanent identity/)
    end
  end
end
