# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeAppSwitch::ProfileWriter do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:actor) { create(:user, company: company, organization: organization, role: :org_admin) }
  let(:activated_at) { 3.days.ago.change(usec: 0) }

  it "keeps a client-managed company client-managed when the switch splits today's version" do
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
        client_portal_enabled: true,
        employee_portal_enabled: true,
        options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
        lifecycle_mode_activated_at: activated_at
      )
    )
    expect(CompanyFeatures.for(company).employee_lifecycle_mode).to eq("client_managed")

    written = company.with_lock do
      described_class.apply!(company: company, actor: actor, values: { "employee_portal_enabled" => false }, reason: "Pause the employee app")
    end

    expect(written.map(&:version)).to eq([ 2 ])
    expect(written.first.lifecycle_mode_activated_at).to eq(activated_at)
    expect(CompanyFeatures.for(company.reload).employee_lifecycle_mode).to eq("client_managed")
  end
end
