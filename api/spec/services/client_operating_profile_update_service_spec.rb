# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientOperatingProfiles::UpdateService do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: create(:company, organization: company.organization), role: "manager") }
  let!(:assignment) { create(:company_assignment, company: company, user: actor) }
  let(:start) { PayrollBusinessClock.today + 7 }

  before do
    create(:pay_period, company: company, start_date: start, end_date: start + 13, pay_date: start + 18)
  end

  def save_profile
    described_class.new(
      company: company, actor: actor, effective_on: start.iso8601,
      changes: { "tips.default": "already_paid_out" }, reason: "Document tips treatment", lock_version: 0
    ).call
  end

  it "normalizes symbol keys before looking up submitted values" do
    expect(save_profile.option_value("tips.default")).to eq("already_paid_out")
  end

  it "denies a stale actor after deactivation" do
    User.where(id: actor.id).update_all(active: false)
    expect(actor).to be_active
    expect { save_profile }.to raise_error(described_class::Forbidden)
    expect(company.client_operating_profiles).to be_empty
  end

  it "denies stale memoized access after revocation of the target assignment" do
    expect(actor.can_access_company?(company.id)).to be(true)
    assignment.destroy!
    expect { save_profile }.to raise_error(described_class::Forbidden)
    expect(company.client_operating_profiles).to be_empty
  end
end
