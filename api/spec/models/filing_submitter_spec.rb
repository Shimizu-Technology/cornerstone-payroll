# frozen_string_literal: true

require "rails_helper"
RSpec.describe FilingSubmitter do
  it "permits an incomplete profile, identifies missing settings, and validates identifiers" do
    profile = described_class.new(organization: create(:organization))
    expect(profile).to be_valid
    expect(profile.missing_fields).to include(:ein, :bso_user_id)
    profile.bso_user_id = "password-too-long"
    profile.ein = "123"
    expect(profile).not_to be_valid
  end

  it "enforces one profile per practice" do
    first = described_class.create!(organization: create(:organization))
    expect(described_class.new(organization: first.organization)).not_to be_valid
  end

  it "validates employer defaults and employee suffixes" do
    company = build(:company)
    expect(company.kind_of_employer).to eq("N")
    expect(company.employment_code).to eq("R")
    company.employment_code = "X"
    expect(company).not_to be_valid
    employee = build(:employee, name_suffix: "Jr.")
    expect(employee).to be_valid
    expect(employee.name_suffix).to eq("JR")
    employee.name_suffix = "Esquire"
    expect(employee).not_to be_valid
  end
end
