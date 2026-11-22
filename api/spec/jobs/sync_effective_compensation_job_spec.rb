# frozen_string_literal: true

require "rails_helper"

RSpec.describe SyncEffectiveCompensationJob do
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company, pay_rate: 15, hire_date: Date.new(2026, 1, 1)) }
  let!(:rate) { employee.employee_wage_rates.create!(label: "Regular", rate: 15, is_primary: true) }

  around { |example| travel_to(Time.zone.parse("2026-11-20 12:00:00 +10:00")) { example.run } }

  before do
    EmployeeCompensationChangeService.new(
      employee: employee, actor: nil, source: "staff", reason: "Annual raise", effective_on: "2026-12-01",
      pay_rate: 17, wage_rate_edits: [ { id: rate.id, rate: 17 } ]
    ).call!
  end

  it "is scheduled daily at 00:05 Guam time" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "sync_effective_compensation")
    expect(schedule).to include("class" => "SyncEffectiveCompensationJob", "schedule" => "5 0 * * * Pacific/Guam")
  end

  it "defaults to today's Guam date" do
    expect(EmployeeCompensationChangeService).to receive(:sync_cache!).at_least(:once).with(anything, as_of: Date.new(2026, 11, 20)).and_call_original
    EmployeeCompensationChangeService.writing_for(employee.id) { employee.update_columns(pay_rate: 99) }
    described_class.perform_now
    expect(employee.reload.pay_rate).to eq(15)
  end

  it "does nothing before the effective date" do
    described_class.perform_now
    expect(employee.reload.pay_rate).to eq(15)
    expect(rate.reload.rate).to eq(15)
  end

  it "refreshes the pay-rate and wage-rate cache columns on the effective date" do
    described_class.perform_now(as_of: "2026-12-01")
    expect(employee.reload.pay_rate).to eq(17)
    expect(rate.reload.rate).to eq(17)
    expect(employee.compensation_on(Date.new(2026, 12, 1)).pay_rate).to eq(17)
  end

  it "catches up a change whose start date it missed" do
    described_class.perform_now(as_of: "2026-12-20")
    expect(employee.reload.pay_rate).to eq(17)
  end
end
