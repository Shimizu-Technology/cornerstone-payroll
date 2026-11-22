# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientOperatingProfile, type: :model do
  let(:company) { create(:company) }

  def build_profile(**overrides)
    described_class.new(
      {
        company: company,
        effective_on: Date.new(2026, 1, 1),
        ends_on: nil,
        version: 1,
        offering: "payroll_service",
        hours_source: "manual",
        intake_adapter: nil,
        client_portal_enabled: false,
        employee_portal_enabled: false,
        options: {}
      }.merge(overrides)
    )
  end

  it "saves a valid operating profile and resolves catalog defaults" do
    profile = build_profile
    expect(profile).to be_valid
    profile.save!

    expect(profile.option_value("tips.default")).to eq("paid_in_check")
    expect(profile.option_value("employee_portal.features.stubs")).to be(false)
    expect(profile.option_value("subdomain_enabled")).to be(false)
    expect(profile.option_value("time_module_enabled")).to be(false)
  end

  it "rejects unknown option keys at top-level and nested paths" do
    top_level = build_profile(options: { "nonexistent_toggle" => true })
    expect(top_level).not_to be_valid
    expect(top_level.errors[:options]).to include("contains unknown option key 'nonexistent_toggle'")

    nested = build_profile(options: { "employee_portal" => { "features" => { "loans" => true } } })
    expect(nested).not_to be_valid
    expect(nested.errors[:options]).to include("contains unknown option key 'employee_portal.features.loans'")

    locked_review = build_profile(options: { "client_portal" => { "review_first" => { "bank" => false } } })
    expect(locked_review).not_to be_valid
    expect(locked_review.errors[:options]).to include("contains unknown option key 'client_portal.review_first.bank'")
  end

  it "validates intake_adapter against hours_source and registered adapters" do
    missing_adapter = build_profile(hours_source: "intake_adapter", intake_adapter: nil)
    expect(missing_adapter).not_to be_valid
    expect(missing_adapter.errors[:intake_adapter]).to include("is required when hours_source is intake_adapter")

    unknown_adapter = build_profile(hours_source: "intake_adapter", intake_adapter: "unknown_adapter")
    expect(unknown_adapter).not_to be_valid
    expect(unknown_adapter.errors[:intake_adapter]).to include("must be a registered intake adapter")

    extra_adapter = build_profile(hours_source: "manual", intake_adapter: "mosa_revel")
    expect(extra_adapter).not_to be_valid
    expect(extra_adapter.errors[:intake_adapter]).to include("must be blank unless hours_source is intake_adapter")

    valid_adapter = build_profile(hours_source: "intake_adapter", intake_adapter: "mosa_revel")
    expect(valid_adapter).to be_valid
  end

  it "allows adjacent non-overlapping versions for the same company" do
    v1 = build_profile(effective_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 6, 30), version: 1)
    v1.save!

    v2 = build_profile(
      effective_on: Date.new(2026, 7, 1),
      ends_on: nil,
      version: 2,
      offering: "payroll_portals",
      client_portal_enabled: true
    )
    expect(v2).to be_valid
    v2.save!

    expect(described_class.for_date(company.id, Date.new(2026, 6, 30))).to eq(v1)
    expect(described_class.for_date(company.id, Date.new(2026, 7, 1))).to eq(v2)
  end

  it "rejects overlapping versions in model validation and at the database exclusion constraint" do
    build_profile(effective_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 6, 30), version: 1).save!

    overlapping = build_profile(effective_on: Date.new(2026, 6, 30), ends_on: nil, version: 2)
    expect(overlapping).not_to be_valid
    expect(overlapping.errors[:base]).to include("Operating profile effective dates overlap an existing version for this company")

    # Bypass ActiveRecord validations to prove the PostgreSQL GiST exclusion constraint enforces non-overlap.
    expect {
      overlapping.save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid, /client_operating_profiles_no_overlapping_dates/)
  end

  it "rejects a second open-ended version overlapping an existing open-ended version in the database" do
    build_profile(effective_on: Date.new(2026, 1, 1), ends_on: nil, version: 1).save!

    second_open = build_profile(effective_on: Date.new(2026, 8, 1), ends_on: nil, version: 2)
    expect(second_open).not_to be_valid

    expect {
      second_open.save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "allows identical effective date ranges for different companies" do
    other_company = create(:company, organization: company.organization)
    build_profile(company: company, effective_on: Date.new(2026, 1, 1), ends_on: nil, version: 1).save!

    other = build_profile(company: other_company, effective_on: Date.new(2026, 1, 1), ends_on: nil, version: 1)
    expect(other).to be_valid
    other.save!
  end

  it "enforces ends_on >= effective_on in both model and database" do
    invalid = build_profile(effective_on: Date.new(2026, 6, 1), ends_on: Date.new(2026, 5, 31))
    expect(invalid).not_to be_valid
    expect(invalid.errors[:ends_on]).to include("must be on or after the effective date")

    expect {
      invalid.save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid, /client_operating_profiles_dates_check/)
  end

  it "enforces check constraints for offering, hours_source, and intake_adapter shape in the database" do
    bad_offering = build_profile(offering: "invalid_tier")
    expect {
      bad_offering.save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid, /client_operating_profiles_offering_check/)

    bad_hours = build_profile(hours_source: "magic")
    expect {
      bad_hours.save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid, /client_operating_profiles_hours_source_check/)

    bad_adapter_shape = build_profile(hours_source: "intake_adapter", intake_adapter: nil)
    expect {
      bad_adapter_shape.save!(validate: false)
    }.to raise_error(ActiveRecord::StatementInvalid, /client_operating_profiles_intake_adapter_shape_check/)
  end
end
