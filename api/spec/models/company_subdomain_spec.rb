# frozen_string_literal: true

require "rails_helper"

RSpec.describe Company, "client subdomain slugs" do
  it "allows a nullable slug and lowercase DNS labels from 3 to 40 characters" do
    [ nil, "a-1", "a" * 40 ].each do |slug|
      expect(build(:company, subdomain_slug: slug)).to be_valid
    end
  end

  it "rejects malformed and reserved slugs" do
    invalid_slugs = [ "", "ab", "a" * 41, "MoSas", "mo_sas", "mo.sas", "mo/sas", "café", "-abc", "abc-", "abc\n" ]
    reserved_slugs = %w[payroll www api admin app staging clerk accounts mail status docs support tax aire-api shimizu my]
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
