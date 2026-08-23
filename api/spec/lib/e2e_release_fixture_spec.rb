# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("lib/e2e_release_fixture")

RSpec.describe E2eReleaseFixture do
  around do |example|
    original_mode = ENV["E2E_TEST_MODE"]
    example.run
  ensure
    ENV["E2E_TEST_MODE"] = original_mode
  end

  it "refuses to run without the explicit test-mode guard" do
    ENV.delete("E2E_TEST_MODE")

    expect {
      described_class.seed!(output_path: Rails.root.join("tmp/unguarded-e2e-fixture.json"))
    }.to raise_error(/only in Rails test with E2E_TEST_MODE=true/)
  end

  it "creates only synthetic release data and writes the browser manifest" do
    annual_config = AnnualTaxConfig.create!(
      tax_year: 2026,
      ss_wage_base: 184_500,
      ss_rate: 0.062,
      medicare_rate: 0.0145,
      additional_medicare_rate: 0.009,
      additional_medicare_threshold: 200_000,
      is_active: true
    )
    annual_config.filing_status_configs.create!(
      filing_status: "single",
      standard_deduction: 16_100
    )
    ENV["E2E_TEST_MODE"] = "true"
    output = Rails.root.join("tmp/e2e-release-fixture-spec.json")

    fixture = described_class.seed!(output_path: output)
    manifest = JSON.parse(output.read)

    expect(manifest.fetch("schema_version")).to eq(1)
    expect(manifest).not_to have_key("time_tracking_source_secret")
    expect(Organization.find(fixture.fetch(:organization_id)).slug).to eq("gate-0-synthetic-firm")
    expect(Employee.find(fixture.fetch(:employee_id)).full_name).to eq("Avery Example")
    expect(User.find_by!(email: fixture.fetch(:inactive_user_email))).not_to be_active
    expect(TimeTrackingImport.where(pay_period_id: fixture.fetch(:time_import_pay_period_id)).count).to eq(2)
  ensure
    FileUtils.rm_f(output) if output
  end
end
