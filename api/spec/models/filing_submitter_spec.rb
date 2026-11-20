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

  it "rejects the same invalid RA fields at save time as the generator" do
    profile = described_class.new(organization: create(:organization), ein: "00-1234567", contact_phone: "67155512345", contact_email: "filing.@example.com", state: "XX", zip: "123")
    expect(profile).not_to be_valid
    expect(profile.errors.full_messages.join).to include("EIN", "10 digits", "SSA email", "ZIP")
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
  it "strips state and ZIP whitespace before validation and explains full state names" do
    profile = described_class.new(organization: create(:organization), state: " GU ", zip: " 96910 ")
    profile.valid?
    expect(profile.errors.full_messages.join).not_to include("state and ZIP")
    expect(profile.state).to eq("GU")
    expect(profile.zip).to eq("96910")
    profile.state = "Guam"
    profile.valid?
    expect(profile.errors.full_messages.join).to include("Use the 2-letter code, e.g. GU")
  end
  it "normalizes TCC whitespace on save and stores blanks as nil" do
    profile = described_class.create!(organization: create(:organization), tcc: "     ")
    expect(profile.reload.tcc).to be_nil
    profile.update!(tcc: " ABCDE ")
    expect(profile.reload.tcc).to eq("ABCDE")
  end
end
