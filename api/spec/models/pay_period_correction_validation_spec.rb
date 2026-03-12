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
end
