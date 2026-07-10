# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::ApplyService do
  let!(:company) { create(:company) }
  let!(:pay_period) { create(:pay_period, company: company) }
  let!(:employee) { create(:employee, company: company, pay_rate: 20.00) }
  let!(:session) { create(:payroll_intake_session, company: company, pay_period: pay_period, status: "previewed") }
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
end
