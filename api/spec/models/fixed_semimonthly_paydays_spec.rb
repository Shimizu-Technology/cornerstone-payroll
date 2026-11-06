# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Fixed semimonthly scheduled paydays" do
  let(:company) { create(:company, pay_frequency: "semimonthly") }
  let!(:schedule) do
    CompanyPaySchedule.create!(company: company, frequency: "semimonthly", period_rule: "semimonthly",
      pay_date_rule: "semimonthly_15th_and_month_end", timezone: "Pacific/Guam",
      source: "operator_confirmed", confirmation_status: "needs_confirmation", effective_on: Date.new(2020, 1, 1))
  end

  [
    [ "2026-01-15", "2026-01-31" ],
    [ "2026-01-31", "2026-02-15" ],
    [ "2026-02-15", "2026-02-28" ],
    [ "2026-02-28", "2026-03-15" ],
    [ "2028-02-15", "2028-02-29" ],
    [ "2028-02-29", "2028-03-15" ],
    [ "2026-12-31", "2027-01-15" ]
  ].each do |period_end, payday|
    it "keeps #{period_end} scheduled for #{payday} without weekend or holiday adjustment" do
      expect(schedule.scheduled_pay_date_for(Date.iso8601(period_end))).to eq(Date.iso8601(payday))
    end
  end

  it "rejects a shifted regular payday but allows separately identified adjustment runs" do
    period = build(:pay_period, company: company, start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 31))
    expect(period).to be_valid
    period.pay_date = Date.new(2026, 9, 1)
    expect(period).not_to be_valid
    expect(period.errors[:pay_date]).to include(/weekends and holidays do not shift/)
    period.run_purpose = "adjustment"
    expect(period).to be_valid
  end

  it "rejects irregular period boundaries under the fixed schedule" do
    period = build(:pay_period, company: company, start_date: Date.new(2026, 8, 2), end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 31))
    expect(period).not_to be_valid
    expect(period.errors[:base]).to include(/1st–15th/)
  end

  it "revalidates the scheduled payday when an adjustment becomes a regular run" do
    period = create(:pay_period, company: company, start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 15),
      pay_date: Date.new(2026, 9, 1), run_purpose: "adjustment")
    expect(period.update(run_purpose: "regular")).to be(false)
    expect(period.errors[:pay_date]).to include(/weekends and holidays do not shift/)
  end

  it "does not retroactively move previously recorded paydays when configuration changes" do
    schedule.update!(pay_date_rule: "manual")
    period = create(:pay_period, company: company, start_date: Date.new(2026, 8, 1), end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 9, 1))
    schedule.update!(pay_date_rule: "semimonthly_15th_and_month_end")
    expect(period.reload.update(notes: "Historical scheduled date retained")).to be(true)
    expect(period.pay_date).to eq(Date.new(2026, 9, 1))
  end
end
