# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::VerifiedHistoryManifestExtension do
  let(:manifest) do
    {
      "version" => 1,
      "identity_links" => [ {
        "source_user_id" => "10",
        "source_user_uuid" => "AIRE-UUID",
        "employee_id" => 20,
        "employee_name" => "Traven Kaae",
        "employee_status" => "active"
      } ],
      "delivered_checks" => [],
      "issued_entries" => [],
      "classification_cases" => [],
      "finalized_batch_entries" => []
    }
  end

  let(:check) do
    {
      "payroll_item_id" => 30,
      "employee_id" => 20,
      "payment_delivery_method" => "paper_check",
      "check_number" => "003010",
      "net_pay" => "777.00",
      "regular_hours" => "25.90",
      "overtime_hours" => "0.00"
    }
  end

  let(:current_adjustment) do
    {
      "source_time_entry_id" => "2000",
      "source_user_uuid" => "aire-uuid",
      "original_work_date" => "2026-09-15",
      "regular_hours" => "25.90",
      "overtime_hours" => "0.00",
      "category" => { "name" => "Flight Hours" }
    }
  end

  let(:carryover_adjustment) do
    current_adjustment.merge(
      "source_time_entry_id" => "1508",
      "original_work_date" => "2026-08-11",
      "regular_hours" => "6.10"
    )
  end

  let(:extension) do
    {
      "version" => 1,
      "pay_periods" => [ {
        "pay_period_id" => 76,
        "start_date" => "2026-09-01",
        "end_date" => "2026-09-15",
        "delivered_on" => "2026-09-23",
        "checks" => [ check ],
        "aire_employees" => [ {
          "source_user_uuid" => "aire-uuid",
          "display_name" => "Traven Kaae",
          "adjustments" => [ current_adjustment, carryover_adjustment ]
        } ]
      } ]
    }
  end

  it "adds exact current-period entries and leaves older carryover unpaid" do
    result = described_class.new(manifest:, extension:).call

    expect(result.fetch("delivered_checks").sole).to include(
      "payroll_item_id" => 30,
      "pay_period_id" => 76,
      "check_number" => "003010",
      "delivered_on" => "2026-09-23"
    )
    expect(result.fetch("issued_entries").sole).to include(
      "source_time_entry_id" => "2000",
      "source_user_uuid" => "aire-uuid",
      "regular_hours" => "25.90"
    )
    expect(result.fetch("issued_entries").map { |row| row.fetch("source_time_entry_id") }).not_to include("1508")
    expect(manifest.fetch("delivered_checks")).to be_empty
  end

  it "fails closed when AIRE current-period hours differ from the issued check" do
    extension.dig("pay_periods", 0, "checks", 0)["regular_hours"] = "32.10"

    expect { described_class.new(manifest:, extension:).call }
      .to raise_error(described_class::Error, /do not match payroll/)
  end

  it "records an equal-total regular/overtime split as a classification case" do
    current_adjustment.merge!("regular_hours" => "24.90", "overtime_hours" => "1.00")

    result = described_class.new(manifest:, extension:).call

    expect(result.fetch("issued_entries")).to be_empty
    expect(result.fetch("classification_cases").sole).to include(
      "payroll_item_id" => 30,
      "source_user_uuid" => "aire-uuid",
      "source_time_entry_ids" => [ "2000" ]
    )
    expect(result.dig("classification_cases", 0, "source_entries", 0)).to include(
      "regular_hours" => "24.90",
      "overtime_hours" => "1.00"
    )
  end

  it "fails closed when approved AIRE hours have no delivered check" do
    extension.dig("pay_periods", 0)["checks"] = []

    expect { described_class.new(manifest:, extension:).call }
      .to raise_error(described_class::Error, /no delivered check/)
  end

  it "fails closed when the same AIRE employee appears twice in one period" do
    employee = extension.dig("pay_periods", 0, "aire_employees", 0)
    extension.dig("pay_periods", 0, "aire_employees") << JSON.parse(JSON.generate(employee))

    expect { described_class.new(manifest:, extension:).call }
      .to raise_error(described_class::Error, /duplicate employees/)
  end

  it "fails closed when a positive-hour payroll check has no AIRE source entries" do
    extension.dig("pay_periods", 0)["aire_employees"] = []

    expect { described_class.new(manifest:, extension:).call }
      .to raise_error(described_class::Error, /has hours but no matching AIRE source entries/)
  end

  it "allows a delivered salary check without source time" do
    extension.dig("pay_periods", 0)["aire_employees"] = []
    extension.dig("pay_periods", 0, "checks", 0)["employment_type"] = "salary"

    result = described_class.new(manifest:, extension:).call

    expect(result.fetch("delivered_checks").sole).to include("payroll_item_id" => 30)
    expect(result.fetch("issued_entries")).to be_empty
  end

  it "rejects a source entry already assigned to a finalized batch" do
    manifest.fetch("finalized_batch_entries") << {
      "payroll_item_id" => 99,
      "source_time_entry_id" => "2000"
    }
    current_adjustment.merge!("regular_hours" => "24.90", "overtime_hours" => "1.00")

    expect { described_class.new(manifest:, extension:).call }
      .to raise_error(described_class::Error, /multiple payment paths/)
  end
end
