# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::Adapters::SpikeEmail do
  let!(:company) { create(:company) }
  let!(:pay_period) do
    create(
      :pay_period,
      company: company,
      start_date: Date.new(2026, 6, 14),
      end_date: Date.new(2026, 6, 27),
      pay_date: Date.new(2026, 7, 3)
    )
  end
  let!(:employee) { create(:employee, company: company, first_name: "Alice", last_name: "Barista") }
  let(:detected_period) { { start_date: "2026-06-14", end_date: "2026-06-27" } }

  it "derives the paid split from the two legal-week totals" do
    result = described_class.new(pay_period: pay_period, company: company).normalize(
      detected_period: detected_period,
      extracted_rows: [
        {
          employee_name: employee.full_name,
          week1_hours: 41,
          week2_hours: 39,
          total_hours: 80,
          total_tips: 25
        }
      ]
    )

    row = result.fetch(:rows).first
    expect(row).to include(regular_hours: 79.0, overtime_hours: 1.0, validation_errors: [])
    expect(result.dig(:evidence, "source_period")).to eq(
      "start_date" => "2026-06-14",
      "end_date" => "2026-06-27"
    )
  end

  it "requires exact source-period evidence" do
    adapter = described_class.new(pay_period: pay_period, company: company)

    expect { adapter.normalize(extracted_rows: [], detected_period: nil) }
      .to raise_error(ArgumentError, /must show the complete pay-period/)
    expect do
      adapter.normalize(
        extracted_rows: [],
        detected_period: { start_date: "2026-06-15", end_date: "2026-06-28" }
      )
    end.to raise_error(ArgumentError, /does not match this pay period/)
  end

  it "blocks positive total-only hours until both legal weeks are supplied" do
    result = described_class.new(pay_period: pay_period, company: company).normalize(
      detected_period: detected_period,
      extracted_rows: [ { employee_name: employee.full_name, total_hours: 45.25, total_tips: 25 } ]
    )

    expect(result.dig(:rows, 0, :validation_errors).pluck(:code)).to include("weekly_hours_required")
  end

  it "blocks contradictory source totals and overtime splits" do
    result = described_class.new(pay_period: pay_period, company: company).normalize(
      detected_period: detected_period,
      extracted_rows: [
        {
          employee_name: employee.full_name,
          week1_hours: 45,
          week2_hours: 35,
          total_hours: 85,
          regular_hours: 80,
          overtime_hours: 0,
          total_tips: 25
        }
      ]
    )

    expect(result.dig(:rows, 0, :validation_errors).pluck(:code)).to contain_exactly(
      "weekly_total_mismatch",
      "overtime_split_mismatch"
    )
  end
end
