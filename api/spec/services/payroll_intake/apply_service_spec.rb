# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::ApplyService do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, role: "admin") }
  let!(:workweek) do
    CompanyWorkweek.create!(
      company: company,
      starts_on_weekday: 0,
      starts_at_minutes: 0,
      timezone: "Pacific/Guam",
      source: "operator_confirmed",
      confirmation_status: "confirmed",
      effective_on: Date.new(2023, 1, 1),
      confirmed_by: actor,
      confirmed_at: Time.current,
      notes: "Confirmed for intake specs"
    )
  end
  let!(:pay_period) do
    create(
      :pay_period,
      company: company,
      company_workweek: workweek,
      start_date: Date.new(2024, 1, 7),
      end_date: Date.new(2024, 1, 20),
      pay_date: Date.new(2024, 1, 26)
    )
  end
  let!(:employee) { create(:employee, company: company, pay_rate: 20.00) }
  let!(:session) do
    create(
      :payroll_intake_session,
      company: company,
      pay_period: pay_period,
      status: "previewed",
      evidence_snapshot: {
        "workweek" => PayrollIntake::WorkweekEvidence.new(pay_period: pay_period).capture!,
        "source_period" => { "start_date" => pay_period.start_date.iso8601, "end_date" => pay_period.end_date.iso8601 }
      }
    )
  end
  let!(:row) do
    create(:payroll_intake_row,
      payroll_intake_session: session,
      employee: employee,
      week1_tips: 42.25,
      week2_tips: 57.75,
      reported_tips: 100.00,
      tips_paid_out: 100.00)
  end

  before do
    allow_any_instance_of(PayrollItem).to receive(:calculate!) do |item|
      item.gross_pay = (item.hours_worked.to_f * item.pay_rate.to_f + item.overtime_hours.to_f * item.pay_rate.to_f * 1.5 + item.reported_tips.to_f).round(2)
      item.total_deductions = item.tips_paid_out.to_f
      item.net_pay = (item.gross_pay.to_f - item.total_deductions.to_f).round(2)
      item.save!
    end
  end

  it "persists source tip components for CEO payroll register exports" do
    result = described_class.new(session: session).call

    expect(result[:errors]).to be_empty
    payroll_item = row.reload.applied_payroll_item
    expect(payroll_item.custom_columns_data.fetch("tip_components")).to eq([
      { "label" => "Tips 1", "amount" => 42.25 },
      { "label" => "Tips 2", "amount" => 57.75 }
    ])
  end

  it "blocks stored validation errors even when warnings are acknowledged" do
    row.update!(validation_errors: [ { code: "source_total_mismatch", message: "Source totals conflict", severity: "error" } ])

    result = described_class.new(session: session, acknowledge_warnings: true).call

    expect(result[:errors].first.fetch(:error)).to eq("Source totals conflict")
    expect(pay_period.payroll_items.reload).to be_empty
  end

  it "allows missing weekly evidence to be repaired without changing the extracted total" do
    row.update!(
      week1_hours: 0,
      week2_hours: 0,
      regular_hours: 62,
      overtime_hours: 0,
      validation_errors: [
        { code: "weekly_hours_required", message: "Enter both legal weeks", severity: "error" }
      ]
    )

    result = described_class.new(
      session: session,
      row_overrides: [
        {
          id: row.id,
          employee_id: employee.id,
          week1_hours: 41,
          week2_hours: 21,
          regular_hours: 61,
          overtime_hours: 1
        }
      ]
    ).call

    expect(result[:errors]).to be_empty
    item = pay_period.payroll_items.find_by!(employee: employee)
    expect(item.hours_worked.to_f).to eq(61.0)
    expect(item.overtime_hours.to_f).to eq(1.0)
    expect(row.reload).to have_attributes(
      week1_hours: 41.to_d,
      week2_hours: 21.to_d,
      regular_hours: 61.to_d,
      overtime_hours: 1.to_d,
      validation_errors: []
    )
  end

  it "rejects overrides whose weekly hours change the extracted total" do
    result = described_class.new(
      session: session,
      row_overrides: [
        {
          id: row.id,
          employee_id: employee.id,
          week1_hours: 40,
          week2_hours: 40,
          regular_hours: 80,
          overtime_hours: 0
        }
      ]
    ).call

    expect(result[:errors].first.fetch(:error)).to include("must equal the extracted row total")
    expect(pay_period.payroll_items.reload).to be_empty
  end

  it "rejects regular and overtime overrides that disagree with the legal weekly calculation" do
    result = described_class.new(
      session: session,
      row_overrides: [
        {
          id: row.id,
          employee_id: employee.id,
          week1_hours: 41,
          week2_hours: 21,
          regular_hours: 62,
          overtime_hours: 0
        }
      ]
    ).call

    expect(result[:errors].first.fetch(:error)).to include("legal weekly calculation")
    expect(pay_period.payroll_items.reload).to be_empty
  end

  it "blocks a preview after its confirmed workweek evidence changes" do
    workweek.update!(notes: "Confirmed workweek evidence changed")

    expect { described_class.new(session: session).call }
      .to raise_error(ArgumentError, /legal workweek changed after this payroll intake preview/)
    expect(pay_period.payroll_items.reload).to be_empty
  end
end
