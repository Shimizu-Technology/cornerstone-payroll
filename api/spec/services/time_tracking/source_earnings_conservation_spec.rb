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

  def apply!(same_rate: false, mapping_change: nil, source_kinds: %w[carryover current], signed_acknowledgement: false)
    category = next_import.raw_payload["employees"].first["adjustments"].first
    mappings = source_kinds.map do |kind|
      { source_category_id: category["source_category_id"], source_category_key: category.dig("category", "key"),
        source_category_name: category.dig("category", "name"), source_kind: kind,
        employee_wage_rate_id: kind == "carryover" && !same_rate ? carry_rate.id : rate.id }
    end
    mappings.first.merge!(mapping_change) if mapping_change
    result = TimeTracking::ApplyImportService.new(import: next_import,
      mappings: [ { source_user_id: "42", employee_id: employee.id, wage_rate_mappings: mappings } ], applied_by: actor,
      acknowledge_negative_adjustments: signed_acknowledgement,
      negative_adjustment_note: signed_acknowledgement ? "Reviewed the signed source hours correction." : nil).call
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

  describe "readonly source basis metadata", type: :request do
    def assert_source_hold(item, expected_reason)
      original = item.reload.attributes
      earnings = item.payroll_item_earnings.order(:id).map(&:attributes)
      allocations = item.time_tracking_entry_allocations.order(:id).map(&:attributes)
      expect(TimeTracking::Client).not_to receive(:new)
      allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(actor)
      allow_any_instance_of(Api::V1::Admin::PayrollItemsController).to receive(:current_user).and_return(actor)
      hold = described_class.hold_reason(item)
      expect(hold).to include(reason: include(expected_reason))
      get "/api/v1/admin/pay_periods/#{next_period.id}", headers: { "X-Company-Id" => company.id.to_s }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("pay_period", "payroll_items").sole.fetch("correction_pay_basis_hold"))
        .to eq("reason" => hold[:reason])
      get "/api/v1/admin/pay_periods/#{next_period.id}/payroll_items/#{item.id}", headers: { "X-Company-Id" => company.id.to_s }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.dig("payroll_item", "correction_pay_basis_hold")).to eq("reason" => hold[:reason])
      expect(item.reload.attributes).to eq(original)
      expect(item.payroll_item_earnings.reload.order(:id).map(&:attributes)).to eq(earnings)
      expect(item.time_tracking_entry_allocations.reload.order(:id).map(&:attributes)).to eq(allocations)
    end

    it "shows captured hourly versus current salary incompatibility without mutations or a source client" do
      item = apply!
      item.calculate!
      item.employee # A loaded old association cannot hide the changed setup.
      employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)
      assert_source_hold(item, "captured pay basis")
    end

    it "returns no hold for compatible imported and ordinary rows or accepted committed history" do
      item = apply!
      item.calculate!
      expect(described_class.hold_reason(item)).to be_nil
      expect(described_class.hold_reason(original_item)).to be_nil
      next_period.update!(status: "calculated")
      lifecycle = PayPeriodLifecycleService.new(pay_period: next_period, actor: actor)
      lifecycle.approve!
      lifecycle.commit!
      saved = item.reload.attributes
      employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)
      expect(described_class.hold_reason(item)).to be_nil
      expect(item.reload.attributes).to eq(saved)
    end

    context "a normally captured hourly contractor" do
      let(:employee) { create(:employee, :contractor, company: company, contractor_pay_type: "hourly", pay_rate: 25) }
      let(:original_item) do
        item = create(:payroll_item, company: company, employee: employee, pay_period: original_period,
          employment_type: "contractor", pay_rate: 25, hours_worked: 4)
        item.calculate!
        original_period.update!(status: "committed", committed_at: Time.current)
        item
      end

      it "exposes the recorded hourly to current flat-fee incompatibility while preserving the captured source" do
        item = apply!
        item.calculate!
        expect(item.time_tracking_entry_allocations.map(&:earning_snapshot))
          .to all(include("employment_type" => "contractor", "contractor_pay_type" => "hourly"))
        employee.update!(contractor_pay_type: "flat_fee", pay_rate: 500)
        assert_source_hold(item, "captured pay basis")
      end
    end
  end

  it "rejects changed frozen batch provenance even when the employee's hours still match" do
    item = apply!
    raw = next_import.raw_payload.deep_dup
    raw["cutoff_at"] = (Time.iso8601(raw["cutoff_at"]) + 1.minute).iso8601
    next_import.update_columns(raw_payload: raw)
    expect { item.calculate! }.to raise_error(ArgumentError, /Imported source hours/)
    expect(item.reload.gross_pay).to eq(0)
  end

  it "rolls back a new salary calculation that would replace captured hourly earnings" do
    item = apply!
    item.calculate!
    original = item.reload.attributes
    original_earnings = item.payroll_item_earnings.order(:id).map(&:attributes)
    employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)
    item.employment_type = employee.employment_type
    item.pay_rate = employee.pay_rate
    expect { item.calculate! }.to raise_error(ArgumentError, /captured pay basis/)
    expect(item.reload.attributes).to eq(original)
    expect(item.payroll_item_earnings.reload.order(:id).map(&:attributes)).to eq(original_earnings)
    expect(item.time_tracking_entry_allocations.count).to eq(2)
  end

  it "rolls back mismatched computed earnings before accepting a calculation" do
    item = apply!
    item.calculate!
    original = item.reload.attributes
    original_earnings = item.payroll_item_earnings.order(:id).map(&:attributes)
    allow_any_instance_of(HourlyPayrollCalculator).to receive(:calculate).and_wrap_original do |method|
      method.call
      earning = item.payroll_item_earnings.detect { |row| row.category == "regular" }
      earning.amount += 1
    end
    expect { item.calculate! }.to raise_error(ArgumentError, /Imported source hours/)
    expect(item.reload.attributes).to eq(original)
    expect(item.payroll_item_earnings.reload.order(:id).map(&:attributes)).to eq(original_earnings)
  end

  describe "worksheet calculation", type: :request do
    it "reports a captured pay-basis error before field or loan draft writes" do
      item = apply!
      item.calculate!
      original = item.reload.attributes
      original_earnings = item.payroll_item_earnings.order(:id).map(&:attributes)
      employee.update!(employment_type: "salary", salary_type: "annual", pay_rate: 52_000)
      allow_any_instance_of(Api::V1::Admin::PayPeriodsController).to receive(:current_user).and_return(actor)
      expect_any_instance_of(PayrollFieldInputApplier).not_to receive(:apply!)
      expect(NamedPayrollLoanInput).not_to receive(:apply!)
      post "/api/v1/admin/pay_periods/#{next_period.id}/run_payroll", headers: { "X-Company-Id" => company.id.to_s },
        params: { employee_ids: [ employee.id ], payroll_field_inputs: { employee.id.to_s => {
          "999" => { mode: "override", amount: 10 }
        } }, named_loan_payments: { employee.id.to_s => { "999" => { mode: "override", amount: 20 } } } }
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("results", "success")).to be_empty
      expect(response.parsed_body.dig("results", "errors")).to contain_exactly(include("employee_id" => employee.id,
        "error" => include("captured pay basis")))
      expect(item.reload.attributes).to eq(original)
      expect(item.payroll_item_earnings.reload.order(:id).map(&:attributes)).to eq(original_earnings)
      expect(item.payroll_item_field_entries).to be_empty
      expect(item.loan_transactions).to be_empty
      expect(item.named_loan_payments).to be_empty
      expect(next_period.reload.status).to eq("draft")
    end
  end

  context "distinct signed source buckets" do
    let(:signed_correction_hours) { -1 }
    let(:next_import) do
      make_import(next_period, 5, "current", "NEXT", daily_lines: [
        { source_time_entry_id: "104", line_key: "current-line", source_kind: "current", source_time_entry_version: 1,
          original_work_date: "2026-10-20", original_week_start: "2026-10-18", total_hours: 6, regular_hours: 6, overtime_hours: 0 },
        { source_time_entry_id: "501", line_key: "signed-correction", source_kind: "correction", source_time_entry_version: 1,
          original_work_date: "2026-10-10", original_week_start: "2026-10-04", total_hours: signed_correction_hours,
          regular_hours: signed_correction_hours, overtime_hours: 0 }
      ])
    end

    def signed_item
      apply!(same_rate: true, source_kinds: %w[current correction], signed_acknowledgement: true)
    end

    it "conserves current plus signed correction through calculation, approval and commitment" do
      item = signed_item
      item.calculate!
      expect(item.reload.hours_worked).to eq(5)
      expect(item.gross_pay).to eq(125)
      expect(item.wage_rate_hours.map { |entry| entry["source_bucket_key"] }.uniq.size).to eq(2)
      expect(item.payroll_item_earnings.map { |earning| [ earning.category, earning.amount ] }).to contain_exactly(
        [ "regular", 150.to_d ], [ "other", -25.to_d ]
      )
      next_period.update!(status: "calculated")
      lifecycle = PayPeriodLifecycleService.new(pay_period: next_period, actor: actor)
      lifecycle.approve!
      lifecycle.commit!
      expect(next_period.reload.status).to eq("committed")
      expect(item.reload.gross_pay).to eq(125)
      expect(item.time_tracking_entry_allocations.sum(:regular_hours)).to eq(5)
      original = item.reload.attributes
      allocations = item.time_tracking_entry_allocations.order(:id).map(&:attributes)
      other = create(:employee, company: company)
      expect(item.update(employee_id: other.id)).to eq(false)
      expect(item.reload.attributes).to eq(original)
      expect(item.time_tracking_entry_allocations.reload.order(:id).map(&:attributes)).to eq(allocations)
    end

    context "a reversal that rounds to zero cents" do
      let(:signed_correction_hours) { -0.01 }

      it "conserves the native zero-cent reversal without treating negative zero as changed money" do
        carry_rate.update!(rate: 0.01)
        item = apply!(source_kinds: %w[correction current], mapping_change: { employee_wage_rate_id: carry_rate.id },
          signed_acknowledgement: true)
        item.calculate!
        expect(item.reload.hours_worked).to eq(5.99)
        expect(item.gross_pay).to eq(150)
        expect(item.payroll_item_earnings.find_by!(category: "other").amount).to eq(0)
        expect(described_class.validate!(item, calculated: true)).to eq(true)
      end
    end

    %w[regular other].each do |category|
      it "rolls back a changed #{category} signed earning during calculation and rejects it before approval" do
        item = signed_item
        item.calculate!
        original = item.reload.attributes
        earnings = item.payroll_item_earnings.reload.order(:id).map(&:attributes)
        allow_any_instance_of(HourlyPayrollCalculator).to receive(:calculate).and_wrap_original do |method|
          method.call
          item.payroll_item_earnings.detect { |earning| earning.category == category }.amount += 1
        end
        expect { item.calculate! }.to raise_error(ArgumentError, /Imported source hours/)
        expect(item.reload.attributes).to eq(original)
        expect(item.payroll_item_earnings.reload.order(:id).map(&:attributes)).to eq(earnings)
        item.payroll_item_earnings.find_by!(category: category).update!(amount: category == "regular" ? 151 : -24)
        next_period.update!(status: "calculated")
        expect { PayPeriodLifecycleService.new(pay_period: next_period, actor: actor).approve! }
          .to raise_error(PayPeriodLifecycleService::InvalidTransitionError, /Imported source hours/)
        expect(next_period.reload.status).to eq("calculated")
        expect(item.reload.check_number).to be_nil
      end
    end
  end
end
