# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::SourceEarningsConservation do
  include_context "exact source correction fixtures"

  let!(:carry_rate) { create(:employee_wage_rate, employee: employee, rate: 10, label: "Carry pay", is_primary: false) }
  let(:next_import) do
    make_import(next_period, 6, "current", "NEXT", daily_lines: [
      { source_time_entry_id: "103", line_key: "carry-line", source_kind: "carryover", source_time_entry_version: 2,
        original_work_date: "2026-10-10", total_hours: 4, regular_hours: 4, overtime_hours: 0 },
      { source_time_entry_id: "104", line_key: "current-line", source_kind: "current", source_time_entry_version: 1,
        original_work_date: "2026-10-20", original_week_start: "2026-10-18", total_hours: 2, regular_hours: 2, overtime_hours: 0 }
    ])
  end

  def apply!(same_rate: false, mapping_change: nil)
    category = next_import.raw_payload["employees"].first["adjustments"].first
    mappings = %w[carryover current].map do |kind|
      { source_category_id: category["source_category_id"], source_category_key: category.dig("category", "key"),
        source_category_name: category.dig("category", "name"), source_kind: kind,
        employee_wage_rate_id: kind == "carryover" && !same_rate ? carry_rate.id : rate.id }
    end
    mappings.first.merge!(mapping_change) if mapping_change
    result = TimeTracking::ApplyImportService.new(import: next_import,
      mappings: [ { source_user_id: "42", employee_id: employee.id, wage_rate_mappings: mappings } ], applied_by: actor).call
    expect(result[:errors]).to eq([])
    next_period.payroll_items.find_by!(employee: employee)
  end

  it "rejects incomplete and unknown explicit mapping dimensions without partial imports" do
    [ { employee_wage_rate_id: nil }, { source_category_id: "invented" }, { source_kind: nil } ].each do |change|
      expect { apply!(mapping_change: change) }.to raise_error(ArgumentError, /earning|source kind/)
      expect(next_period.payroll_items).not_to exist
      expect(next_import.reload.status).to eq("previewed")
      expect(next_import.time_tracking_entry_allocations).not_to exist
    end
  end

  it "captures distinct carry/current selected rates and conserves six hours and ninety dollars after reload and calculation" do
    item = apply!
    expect(item.reload.wage_rate_hours).to contain_exactly(
      include("rate" => 10, "regular_hours" => 4, "source_lines" => [ include("source_kind" => "carryover", "source_time_entry_version" => 2) ]),
      include("rate" => 25, "regular_hours" => 2, "source_lines" => [ include("source_kind" => "current", "source_time_entry_version" => 1) ])
    )
    expect(item.time_tracking_entry_allocations.map { |row| row.earning_snapshot["rate"] }).to contain_exactly(10, 25)
    item.calculate!
    expect(item.reload.gross_pay).to eq(90)
    expect(item.hours_worked).to eq(6)
    expect(described_class.validate!(item, calculated: true)).to eq(true)
  end

  it "keeps both source dimensions even when they select the same wage-rate ID" do
    item = apply!(same_rate: true)
    expect(item.wage_rate_hours.size).to eq(2)
    expect(item.wage_rate_hours.map { |entry| entry["source_bucket_key"] }.uniq.size).to eq(2)
    item.calculate!
    expect(item.reload.gross_pay).to eq(150)
    expect(item.hours_worked).to eq(6)
  end

  it "rejects collapsed worksheet inputs before calculation, item save and approval" do
    item = apply!
    item.calculate!
    frozen = item.reload.attributes
    item.wage_rate_hours = [ item.wage_rate_hours.last ]
    item.hours_worked = 2
    expect { item.calculate! }.to raise_error(ArgumentError, /Imported source hours/)
    expect(item.save).to eq(false)
    expect(item.reload.attributes).to eq(frozen)
    item.update_columns(hours_worked: 2)
    next_period.update_columns(status: "calculated")
    expect { PayPeriodLifecycleService.new(pay_period: next_period, actor: actor).approve! }.to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Imported source hours/)
    expect(next_period.reload.status).to eq("calculated")
  end

  it "rejects stale captured rates and source versions without partial financial effects" do
    item = apply!
    entries = item.wage_rate_hours
    entries.find { |entry| entry["rate"] == 10 }["rate"] = 25
    item.wage_rate_hours = entries
    expect(item.save).to eq(false)
    item.reload
    entries = item.wage_rate_hours
    entries.first["source_lines"].first["source_time_entry_version"] += 1
    item.wage_rate_hours = entries
    expect(item.save).to eq(false)
    expect(item.reload.time_tracking_entry_allocations.count).to eq(2)
    expect(item.check_number).to be_nil
  end

  it "retains captured imported rates when current profiles change" do
    item = apply!
    carry_rate.update!(rate: 99)
    entry = item.wage_rate_hours.first
    normalized = PayrollWageRateInput.normalize(payroll_item: item, entries: [ entry ])
    expect(normalized.first["rate"]).to eq(entry["rate"])
    item.calculate!
    expect(item.reload.gross_pay).to eq(90)
  end
end
