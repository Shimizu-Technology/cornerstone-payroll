# frozen_string_literal: true

require "rails_helper"

RSpec.describe Company, "client subdomain slugs" do
  it "allows a nullable slug and lowercase DNS labels from 3 to 40 characters" do
    [ nil, "a-1", "a" * 40 ].each do |slug|
      expect(build(:company, subdomain_slug: slug)).to be_valid
    end
  end

  it "rejects malformed and reserved slugs" do
    invalid_slugs = [ "", "ab", "a" * 41, "MoSas", "xn--mosas", "mo_sas", "mo.sas", "mo/sas", "café", "-abc", "abc-", "abc\n" ]
    reserved_slugs = %w[payroll www api admin app staging clerk clkmail accounts mail status docs support tax aire aire-api plane shimizu my]
    (invalid_slugs + reserved_slugs).each do |slug|
      company = build(:company, subdomain_slug: slug)
      expect(company).not_to be_valid
      expect(company.errors[:subdomain_slug]).to be_present
    end
  end

  it "enforces uniqueness across organizations and when validation is bypassed" do
    create(:company, subdomain_slug: "example-employer")
    duplicate = build(:company, subdomain_slug: "example-employer")
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:subdomain_slug]).to include("has already been taken")

    duplicate.subdomain_slug = "EXAMPLE-EMPLOYER"
    expect do
      Company.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "requires disabling the effective profile before renaming or removing its slug" do
    company = create(:company, subdomain_slug: "original")
    profile = company.client_operating_profiles.create!(
      effective_on: PayrollBusinessClock.today, version: 1, offering: "payroll_service",
      hours_source: "manual", options: { subdomain_enabled: true }
    )

    [ "renamed", nil ].each do |slug|
      expect(company.update(subdomain_slug: slug)).to be(false)
      expect(company.errors[:subdomain_slug]).to include("cannot change while the current operating profile enables the subdomain")
    end
    profile.update!(options: { subdomain_enabled: false })
    expect(company.update(subdomain_slug: "renamed")).to be(true)
  end

  it "only accepts public branding keys, valid hex colors and public HTTPS logo URLs" do
    company = build(:company, branding: { logo_url: "https://images.example.test/brand.png", primary_color: "#aB123F", accent_color: nil })
    expect(company).to be_valid
    [
      [], nil, { internal_email: "private@example.test" }, { primary_color: "blue" },
      { accent_color: false }
    ].each do |branding|
      company.branding = branding
      expect(company).not_to be_valid
      expect(company.errors[:branding]).to be_present
    end

    %w[
      http://example.test/mark.png https://example.test/mark.png?X-Amz-Signature=test
      https://example.test/mark.png#fragment https://user@example.test/mark.png
      https://127.0.0.1/mark.png https://[::1]/mark.png https://10.0.0.1/mark.png
      https://localhost/mark.png https://staff.internal/mark.png
      https://bucket.r2.cloudflarestorage.com/mark.png https://bucket.s3.us-west-2.amazonaws.com/mark.png
      https://bucket.s3-us-west-2.amazonaws.com/mark.png
    ].each do |logo_url|
      company.branding = { logo_url: logo_url }
      expect(company).not_to be_valid, "unexpected approval for #{logo_url}"
      expect(company.errors[:branding]).to be_present
    end
  end

  it "prevents test workspaces from claiming a subdomain" do
    source = create(:company, subdomain_slug: "example-employer")
    workspace = create(
      :company, organization: source.organization, payroll_environment: "migration_rehearsal",
      migration_source_company: source, migration_rehearsal_status: "ready", test_workspace_purpose: "sandbox"
    )
    workspace.subdomain_slug = source.subdomain_slug
    expect(workspace).not_to be_valid
    expect(workspace.errors[:subdomain_slug]).to include("is only available to live companies")
    expect do
      Company.transaction(requires_new: true) { workspace.update_columns(subdomain_slug: "another-employer") }
    end.to raise_error(ActiveRecord::StatementInvalid, /company_subdomain_requires_live_payroll/)
  end
end
