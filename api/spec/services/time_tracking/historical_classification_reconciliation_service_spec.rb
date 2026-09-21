# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::HistoricalClassificationReconciliationService do
  let(:company) { create(:company) }
  let(:source) { create(:time_tracking_source, company: company, source_type: "aire_services") }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) { create(:employee, company: company, department: create(:department, company: company)) }
  let(:period) do
    create(:pay_period, :committed, company: company, start_date: Date.new(2026, 8, 1),
                                    end_date: Date.new(2026, 8, 15), pay_date: Date.new(2026, 8, 31))
  end
  let(:item) do
    create(:payroll_item, :with_check, company: company, pay_period: period, employee: employee,
                                       hours_worked: 6.1, overtime_hours: 0, pay_rate: 10,
                                       gross_pay: 61, total_additions: 0, net_pay: 50)
  end
  let(:uuid) { SecureRandom.uuid }
  let(:client) { instance_double(TimeTracking::Client) }
  let(:service) { described_class.new(pay_period: period, source: source, actor: actor) }
  let(:record_delivery) { true }
  let(:review) do
    {
      "employees" => [ {
        "source_user_uuid" => uuid,
        "adjustments" => [
          { "source_time_entry_id" => "41", "source_time_entry_version" => 2,
            "source_kind" => "current", "original_work_date" => "2026-08-14",
            "total_hours" => "5.10", "regular_hours" => "5.10", "overtime_hours" => "0.00" },
          { "source_time_entry_id" => "42", "source_time_entry_version" => 1,
            "source_kind" => "current", "original_work_date" => "2026-08-15",
            "total_hours" => "1.00", "regular_hours" => "0.00", "overtime_hours" => "1.00" }
        ]
      } ]
    }
  end

  before do
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
                                        employee: employee, source_user_id: "91", source_user_uuid: uuid)
    employee.employee_wage_rates.create!(label: "Maintenance", rate: 10, active: true, is_primary: true)
    if record_delivery
      create(:check_event, payroll_item: item, user: actor, event_type: "delivered",
                           effective_on: PayrollBusinessClock.today)
    end
    allow(TimeTracking::Client).to receive(:new).and_return(client)
    allow(TimeTracking::Client).to receive(:for_payroll_actor).with(source, actor: actor).and_return(client)
    allow(client).to receive(:payroll_account_link).and_return("account_link" => { "connected" => false })
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(review)
    next_id = 500
    allow(client).to receive(:commit_payroll_manual_allocation) do
      next_id += 1
      { "manual_allocation" => { "id" => next_id.to_s, "version" => 0 } }
    end
    allow(client).to receive(:issue_payroll_manual_allocation) do |args|
      { "manual_allocation" => { "id" => args.fetch(:allocation_id), "version" => 1 } }
    end
  end

  it "marks exact source hours paid once while retaining the historical OT split difference" do
    reconciliation = service.call(payroll_item_id: item.id, source_user_uuid: uuid)

    expect(reconciliation.reload.status).to eq("complete")
    expect(reconciliation).to have_attributes(source_regular_hours: 5.1, source_overtime_hours: 1,
                                               payroll_regular_hours: 6.1, payroll_overtime_hours: 0,
                                               gross_wage_difference: 5)
    expect(reconciliation.note).to include("later review, not automatically paid or deducted")
    expect(reconciliation.time_tracking_manual_allocations.pluck(:status)).to eq(%w[issued issued])
    expect(reconciliation.time_tracking_manual_allocations.sum(:regular_hours)).to eq(5.1)
    expect(reconciliation.time_tracking_manual_allocations.sum(:overtime_hours)).to eq(1)
    expect(client).to have_received(:issue_payroll_manual_allocation).twice

    expect { service.call(payroll_item_id: item.id, source_user_uuid: uuid) }
      .not_to change(TimeTrackingManualAllocation, :count)
  end

  it "refuses to mark hours paid when AIRE and the issued check have different totals" do
    review["employees"][0]["adjustments"][1]["total_hours"] = "1.10"
    review["employees"][0]["adjustments"][1]["overtime_hours"] = "1.10"

    expect { service.call(payroll_item_id: item.id, source_user_uuid: uuid) }
      .to raise_error(described_class::Error, /equal-total hours/)
    expect(TimeTrackingClassificationReconciliation.count).to eq(0)
    expect(TimeTrackingManualAllocation.count).to eq(0)
  end

  context "without a delivered check" do
    let(:record_delivery) { false }

    it "refuses a split exception without actual check-delivery evidence" do
      expect { service.call(payroll_item_id: item.id, source_user_uuid: uuid) }
        .to raise_error(described_class::Error, /check-delivery evidence/)
      expect(TimeTrackingManualAllocation.count).to eq(0)
    end
  end

  it "blocks an ordinary manual link after a historical exception has been established" do
    service.call(payroll_item_id: item.id, source_user_uuid: uuid)

    expect do
      TimeTracking::ManualAllocationService.new(pay_period: period, source: source, actor: actor).create!(
        payroll_item_id: item.id, source_time_entry_id: "43", source_time_entry_version: 0,
        source_user_uuid: uuid, regular_hours: "0.10", overtime_hours: "0.00",
        original_work_date: "2026-08-15", note: "Unreviewed additional source entry"
      )
    end.to raise_error(TimeTracking::ManualAllocationService::Error, /historical classification reconciliation/)
  end

  it "keeps the recorded check evidence immutable after issuance" do
    reconciliation = service.call(payroll_item_id: item.id, source_user_uuid: uuid)

    expect { reconciliation.update!(check_number: "different") }
      .to raise_error(ActiveRecord::RecordInvalid, /cannot be edited/)
    reconciliation.reload
    expect { reconciliation.update!(status: "pending") }
      .to raise_error(ActiveRecord::RecordInvalid, /can only move from pending to complete/)
  end
end
