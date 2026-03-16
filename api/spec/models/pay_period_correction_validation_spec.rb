# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayPeriod, type: :model do
  let(:company) { create(:company) }

  it "requires source_pay_period_id when correction_status is correction" do
    pay_period = build(:pay_period,
      company: company,
      status: "draft",
      correction_status: "correction",
      source_pay_period_id: nil)

    expect(pay_period).not_to be_valid
    expect(pay_period.errors[:source_pay_period_id]).to be_present
  end

  it "treats reportable periods as non-voided originals and correction runs" do
    original = create(:pay_period, company: company, correction_status: nil)
    correction = create(:pay_period, :correction_run, company: company)
    voided = create(:pay_period, :voided, company: company)

    expect(PayPeriod.reportable_periods).to include(original, correction)
    expect(PayPeriod.reportable_periods).not_to include(voided)
    expect(PayPeriod.active_periods).to match_array(PayPeriod.reportable_periods)
  end
end
