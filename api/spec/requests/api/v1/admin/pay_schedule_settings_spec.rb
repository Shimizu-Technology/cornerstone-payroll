# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayScheduleSettings", type: :request do
  let(:company) { create(:company, pay_frequency: "biweekly") }
  let(:admin_user) { create(:user, company: company, role: "admin") }

  before do
    allow_any_instance_of(Api::V1::Admin::PayScheduleSettingsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayScheduleSettingsController).to receive(:current_company).and_return(company)
    allow_any_instance_of(Api::V1::Admin::PayScheduleSettingsController).to receive(:current_user).and_return(admin_user)
  end

  it "returns transparent unconfirmed defaults before configuration" do
    get "/api/v1/admin/pay_schedule_settings"

    expect(response).to have_http_status(:ok)
    settings = response.parsed_body.fetch("pay_schedule_settings")
    expect(settings.dig("pay_schedule", "period_rule")).to eq("manual")
    expect(settings.dig("workweek", "source")).to eq("legacy_system_default")
    expect(settings.dig("workweek", "confirmation_status")).to eq("needs_confirmation")
  end

  it "lets accountants read but not change client schedule configuration" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")
    allow_any_instance_of(Api::V1::Admin::PayScheduleSettingsController)
      .to receive(:current_user).and_return(accountant)

    get "/api/v1/admin/pay_schedule_settings"
    expect(response).to have_http_status(:ok)

    put "/api/v1/admin/pay_schedule_settings", params: { pay_schedule_settings: {} }
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Manager or admin access required")
  end

  it "creates a confirmed effective-dated schedule and legal workweek" do
    put "/api/v1/admin/pay_schedule_settings", params: {
      pay_schedule_settings: {
        effective_on: "2026-08-10",
        pay_schedule: {
          frequency: "biweekly",
          period_rule: "biweekly",
          period_start_weekday: 0,
          period_anchor_date: "2026-08-09",
          pay_date_rule: "days_after_period_end",
          pay_date_offset_days: 6,
          timezone: "Pacific/Guam",
          notes: "Confirmed by client"
        },
        workweek: {
          starts_on_weekday: 0,
          starts_at_minutes: 0,
          timezone: "Pacific/Guam",
          notes: "Confirmed by client"
        }
      }
    }

    expect(response).to have_http_status(:ok)
    expect(company.company_pay_schedules.last).to be_confirmed
    expect(company.company_workweeks.last).to be_confirmed
    expect(company.company_workweeks.last.confirmed_by).to eq(admin_user)
  end

  it "rejects non-midnight workweeks without closing the current configuration" do
    current_schedule = company.company_pay_schedules.create!(
      frequency: "biweekly",
      period_rule: "manual",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )
    current_workweek = company.company_workweeks.create!(
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )

    put "/api/v1/admin/pay_schedule_settings", params: {
      pay_schedule_settings: {
        effective_on: "2026-08-10",
        pay_schedule: {
          frequency: "biweekly",
          period_rule: "manual",
          pay_date_rule: "manual",
          timezone: "Pacific/Guam",
          notes: "Confirmed by client"
        },
        workweek: {
          starts_on_weekday: 1,
          starts_at_minutes: 480,
          timezone: "Pacific/Guam",
          notes: "Confirmed by client"
        }
      }
    }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include(/must be midnight/)
    expect(current_schedule.reload.ends_on).to be_nil
    expect(current_workweek.reload.ends_on).to be_nil
    expect(company.company_workweeks.count).to eq(1)
  end

  it "replaces a legacy non-midnight workweek with a supported midnight configuration" do
    company.company_pay_schedules.create!(
      frequency: "biweekly",
      period_rule: "manual",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )
    legacy_workweek = company.company_workweeks.create!(
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1)
    )
    legacy_workweek.update_column(:starts_at_minutes, 480)

    put "/api/v1/admin/pay_schedule_settings", params: {
      pay_schedule_settings: {
        effective_on: "2026-08-10",
        pay_schedule: {
          frequency: "biweekly",
          period_rule: "manual",
          pay_date_rule: "manual",
          timezone: "Pacific/Guam",
          notes: "Confirmed replacement schedule"
        },
        workweek: {
          starts_on_weekday: 1,
          starts_at_minutes: 0,
          timezone: "Pacific/Guam",
          notes: "Confirmed midnight replacement"
        }
      }
    }

    expect(response).to have_http_status(:ok)
    expect(legacy_workweek.reload.ends_on).to eq(Date.new(2026, 8, 9))
    expect(company.company_workweeks.find_by!(ends_on: nil)).to have_attributes(
      starts_on_weekday: 1,
      starts_at_minutes: 0,
      confirmation_status: "confirmed"
    )
  end

  it "keeps a future-effective configuration from becoming current early" do
    allow_any_instance_of(Api::V1::Admin::PayScheduleSettingsController)
      .to receive(:configuration_date).and_return(Date.new(2026, 8, 3))
    company.company_pay_schedules.create!(
      frequency: "biweekly",
      period_rule: "manual",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 8, 9)
    )
    company.company_pay_schedules.create!(
      frequency: "semimonthly",
      period_rule: "semimonthly",
      pay_date_rule: "manual",
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: admin_user,
      confirmed_at: Time.current,
      notes: "Confirmed for August 10",
      effective_on: Date.new(2026, 8, 10)
    )
    company.company_workweeks.create!(
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "legacy_system_default",
      confirmation_status: "needs_confirmation",
      effective_on: Date.new(2026, 1, 1),
      ends_on: Date.new(2026, 8, 9)
    )
    company.company_workweeks.create!(
      starts_on_weekday: 1,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      confirmed_by: admin_user,
      confirmed_at: Time.current,
      notes: "Confirmed for August 10",
      effective_on: Date.new(2026, 8, 10)
    )

    get "/api/v1/admin/pay_schedule_settings"

    settings = response.parsed_body.fetch("pay_schedule_settings")
    expect(settings.dig("pay_schedule", "period_rule")).to eq("manual")
    expect(settings.dig("workweek", "starts_on_weekday")).to eq(0)
  end
end
