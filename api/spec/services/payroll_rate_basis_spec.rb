# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollRateBasis do
  it "reports an unavailable source rate before considering its basis" do
    expect(described_class.describe(employment_type: "contractor", contractor_pay_type: "hourly", pay_rate: nil))
      .to eq("Source rate unavailable")
  end

  it "retains salary units and an honest fallback for missing saved salary terms" do
    { "annual" => "USD/year (annual salary)", "per_period" => "USD/pay period", "variable" => "USD/pay period (variable salary)",
      nil => "USD (salary basis not recorded)" }.each do |type, label|
      expect(described_class.describe(employment_type: "salary", salary_type: type, pay_rate: 100))
        .to eq(label)
    end
  end

  it "does not interpret unknown contractor terms as hourly" do
    expect(described_class.describe(employment_type: "contractor", contractor_pay_type: "unknown", pay_rate: 100))
      .to eq("USD (contractor rate basis not recorded)")
  end
end
