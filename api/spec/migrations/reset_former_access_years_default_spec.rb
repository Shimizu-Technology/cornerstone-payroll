# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261125120100_reset_former_access_years_default")

RSpec.describe ResetFormerAccessYearsDefault do
  include ActiveSupport::Testing::TimeHelpers

  def profile(company, years, effective_on:, ends_on: nil, version: 1)
    company.client_operating_profiles.create!(
      effective_on: effective_on, ends_on: ends_on, version: version, offering: "payroll_service",
      hours_source: "manual", options: { employee_portal: { former_access_years: years } }
    )
  end

  it "resets only the untouched old default on current and future profiles" do
    company = create(:company)
    ended = profile(company, 6, effective_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 6, 30))
    current = profile(company, 6, effective_on: Date.new(2026, 7, 1), version: 2)
    chosen = profile(create(:company), 7, effective_on: Date.new(2026, 7, 1))
    missing = create(:company).client_operating_profiles.create!(effective_on: Date.new(2026, 7, 1), version: 1,
      offering: "payroll_service", hours_source: "manual", options: {})

    described_class.new.up

    expect(current.reload.option_value("employee_portal.former_access_years")).to eq(2)
    expect(current.lock_version).to eq(1)
    expect(ended.reload.option_value("employee_portal.former_access_years")).to eq(6)
    expect(chosen.reload.option_value("employee_portal.former_access_years")).to eq(7)
    expect(missing.reload.options).to eq({})
    expect(missing.option_value("employee_portal.former_access_years")).to eq(2)
  end

  it "judges an ended profile by today's date in Guam, not the database's UTC date" do
    company = create(:company)
    # 20:00 UTC on November 25 is already 06:00 on November 26 in Guam.
    travel_to(Time.utc(2026, 11, 25, 20, 0, 0)) do
      ended_yesterday_in_guam = profile(company, 6, effective_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 11, 25))
      ends_today_in_guam = profile(create(:company), 6, effective_on: Date.new(2026, 1, 1), ends_on: Date.new(2026, 11, 26))

      described_class.new.up

      expect(ended_yesterday_in_guam.reload.option_value("employee_portal.former_access_years")).to eq(6)
      expect(ends_today_in_guam.reload.option_value("employee_portal.former_access_years")).to eq(2)
    end
  end
end
