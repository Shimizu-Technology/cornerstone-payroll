# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimeTracking::LiveSnapshotPreviewService do
  let(:company) { create(:company) }
  let(:workweek) do
    CompanyWorkweek.create!(
      company: company, starts_on_weekday: 0, starts_at_minutes: 0,
      timezone: "Pacific/Guam", source: "operator_confirmed",
      confirmation_status: "confirmed", confirmed_by: create(:user, company: company),
      confirmed_at: Time.current, notes: "Confirmed for local snapshot test",
      effective_on: Date.new(2020, 1, 1)
    )
  end
  let(:pay_period) do
    create(:pay_period, company: company, company_workweek: workweek,
                        start_date: Date.new(2026, 8, 16), end_date: Date.new(2026, 8, 31),
                        pay_date: Date.new(2026, 9, 15))
  end
  let(:source) do
    TimeTrackingSource.create!(company: company, name: "AIRE", source_type: "aire_services",
                               base_url: "https://aire.example.com", shared_secret: "secret")
  end
  let(:uuid) { "c7fdfadb-4221-4fca-9bea-ab897fc71465" }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let(:employee) do
    create(:employee, company: company, department: create(:department, company: company),
                      email: "pilot@example.com", pay_rate: 25)
  end
  let(:response) do
    {
      "start_date" => pay_period.start_date.iso8601,
      "end_date" => pay_period.end_date.iso8601,
      "generated_at" => "2026-09-14T01:00:00Z",
      "employees" => [
        {
          "source_user_id" => "17", "source_user_uuid" => uuid,
          "email" => employee.email, "display_name" => employee.full_name,
          "adjustments" => [
            {
              "source_time_entry_id" => "101", "source_time_entry_version" => 2,
              "line_key" => "current:101", "source_kind" => "current",
              "original_work_date" => "2026-08-17", "original_week_start" => "2026-08-16",
              "source_category_id" => "3",
              "category" => { "id" => "3", "key" => "regular", "name" => "Regular" },
              "total_hours" => 8.0, "regular_hours" => 8.0, "overtime_hours" => 0.0
            }
          ],
          "total_hours" => 8.0, "regular_hours" => 8.0, "overtime_hours" => 0.0
        }
      ],
      "exclusions" => [
        { "source_time_entry_id" => "102", "source_user_id" => "17", "reason" => "pending_approval",
          "original_work_date" => "2026-08-18", "held_total_hours" => 4.0,
          "held_regular_hours" => 4.0, "held_overtime_hours" => 0.0 }
      ],
      "issues" => { "negative_adjustment_count" => 0 },
      "summary" => { "total_hours" => 8.0, "regular_hours" => 8.0, "overtime_hours" => 0.0 }
    }
  end

  before do
    allow(TimeTracking::Client).to receive(:for_payroll_actor) do |linked_source, actor:|
      TimeTracking::Client.new(linked_source)
    end
    employee.employee_wage_rates.create!(label: "Regular", rate: 25, is_primary: true, active: true)
    TimeTrackingEmployeeMapping.create!(company: company, time_tracking_source: source,
                                        employee: employee, source_user_id: "17",
                                        source_user_uuid: uuid, source_display_name: employee.full_name)
  end

  it "persists an immutable exact-entry pre-pay snapshot and held exclusions" do
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(response)

    import = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    row = import.processed_payload.fetch("rows").first

    expect(import).to be_live_snapshot
    expect(import).not_to be_finalized_batch
    expect(import.raw_payload.dig("employees", 0, "adjustments", 0)).to include(
      "source_time_entry_id" => "101", "source_time_entry_version" => 2
    )
    expect(row).to include("employee_id" => employee.id, "regular_hours" => 8.0, "ready" => true)
    expect(import.processed_payload.fetch("exclusions").first).to include("reason" => "pending_approval")
    expect(import.update(raw_payload: {})).to be(false)
  end

  it "reuses the saved person mapping and pays new Solo hours through that person's Flight Hours wage" do
    flight_rate = employee.employee_wage_rates.create!(label: "Flight Hours", rate: 30, active: true)
    solo = response.deep_dup
    solo["employees"][0]["adjustments"][0]["source_time_entry_id"] = "202"
    solo["employees"][0]["adjustments"][0]["source_category_id"] = "7"
    solo["employees"][0]["adjustments"][0]["category"] = { "id" => "7", "key" => "aire_solo", "name" => "Solo" }
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(solo)

    import = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    row = import.processed_payload.fetch("rows").sole
    category = row.fetch("categories").sole

    expect(row).to include("employee_id" => employee.id, "match_method" => "saved_mapping", "ready" => true)
    expect(category).to include("name" => "Solo", "employee_wage_rate_id" => flight_rate.id,
                                "wage_rate_match_method" => "solo_to_flight_hours", "payroll_rate_cents" => 3000)
    expect(TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor).call.fetch(:errors)).to be_empty
    item = pay_period.payroll_items.find_by!(employee: employee)
    expect(item.wage_rate_hours.find { |hours| hours["employee_wage_rate_id"] == flight_rate.id })
      .to include("regular_hours" => 8.0)
  end

  it "holds Solo hours when the linked employee lacks a verified Flight Hours wage" do
    solo = response.deep_dup
    solo["employees"][0]["adjustments"][0]["category"] = { "id" => "7", "key" => "aire_solo", "name" => "Solo" }
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(solo)

    row = described_class.new(pay_period: pay_period, source: source, actor: actor).call.processed_payload.fetch("rows").sole

    expect(row.fetch("ready")).to be(false)
    expect(row.fetch("warnings")).to include(include("code" => "unmapped_wage_rate"))
  end

  it "reuses a sole Regular wage for a known AIRE maintenance category" do
    maintenance = response.deep_dup
    maintenance["employees"][0]["adjustments"][0]["category"] =
      { "id" => "3", "key" => "aire_maintenance", "name" => "Aircraft Maintenance" }
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(maintenance)

    import = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    row = import.processed_payload.fetch("rows").sole

    expect(row.fetch("ready")).to be(true)
    expect(row.fetch("categories").sole).to include("wage_rate_match_method" => "sole_regular_wage")
    expect(TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor).call.fetch(:errors)).to be_empty
  end

  it "uses the verified Maintenance wage for Aircraft Maintenance source time" do
    employee.update!(pay_rate: 23)
    maintenance_rate = employee.employee_wage_rates.sole
    maintenance_rate.update!(label: "Maintenance", rate: 23)
    maintenance = response.deep_dup
    maintenance["employees"][0]["adjustments"][0]["category"] =
      { "id" => "3", "key" => "aire_maintenance", "name" => "Aircraft Maintenance" }
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(maintenance)

    import = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    category = import.processed_payload.fetch("rows").sole.fetch("categories").sole

    expect(category).to include("employee_wage_rate_id" => maintenance_rate.id,
                                "wage_rate_match_method" => "aircraft_maintenance", "payroll_rate_cents" => 2300)
    expect(TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor).call.fetch(:errors)).to be_empty
  end

  it "requires review of a new unknown AIRE category even when the employee has one wage" do
    unknown = response.deep_dup
    unknown["employees"][0]["adjustments"][0]["category"] =
      { "id" => "99", "key" => "new_special_work", "name" => "New Special Work" }
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(unknown)

    row = described_class.new(pay_period: pay_period, source: source, actor: actor).call.processed_payload.fetch("rows").sole

    expect(row.fetch("ready")).to be(false)
    expect(row.fetch("warnings")).to include(include("code" => "unmapped_wage_rate"))
  end

  it "holds a permanently mapped inactive employee instead of offering their hours to someone else" do
    employee.update!(status: "terminated", termination_date: pay_period.start_date)
    other = create(:employee, company: company, department: employee.department, email: "other@example.com")
    changed = response.deep_dup
    changed["employees"][0]["email"] = other.email
    changed["employees"][0]["display_name"] = other.full_name
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(changed)

    row = described_class.new(pay_period: pay_period, source: source, actor: actor).call.processed_payload.fetch("rows").sole

    expect(row).to include("employee_id" => employee.id, "match_method" => "inactive_mapping", "ready" => false)
    expect(row.fetch("warnings")).to include(include("code" => "inactive_employee"))
  end

  it "imports direct-deposit AIRE hours with exact-entry links awaiting bank settlement" do
    item = create(:payroll_item, pay_period: pay_period, employee: employee,
                                 payment_delivery_method: "direct_deposit")
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(response)

    import = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    row = import.processed_payload.fetch("rows").first
    expect(row.fetch("ready")).to be(true)

    result = TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor).call
    expect(result.fetch(:errors)).to be_empty
    allocations = TimeTracking::ImportedEntryLinker.new(pay_period: pay_period, actor: actor).call!
    expect(TimeTrackingManualAllocation.find(allocations.sole)).to have_attributes(status: "pending_commit", payroll_item_id: item.id)
  end

  it "keeps the checksum stable when only AIRE generation time changes" do
    later = response.deep_dup.merge("generated_at" => "2026-09-14T01:02:00Z")
    expect(described_class.snapshot_checksum(response)).to eq(described_class.snapshot_checksum(later))
  end

  it "does not silently remap an existing AIRE identity during payroll import" do
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(response)
    other_employee = create(:employee, company: company, department: employee.department)
    import = described_class.new(pay_period: pay_period, source: source, actor: actor).call

    result = TimeTracking::ApplyImportService.new(
      import: import,
      mappings: [ { source_user_id: "17", employee_id: other_employee.id } ],
      applied_by: actor
    ).call

    expect(result.fetch(:errors).first.fetch(:error)).to include("permanent employee link")
    expect(import.reload.status).to eq("previewed")
    expect(TimeTrackingEmployeeMapping.find_by!(time_tracking_source: source, source_user_uuid: uuid).employee_id).to eq(employee.id)
  end

  it "rejects a duplicate AIRE source line" do
    duplicate = response.deep_dup
    duplicate["employees"][0]["adjustments"] << duplicate["employees"][0]["adjustments"].first.deep_dup
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(duplicate)

    expect { described_class.new(pay_period: pay_period, source: source, actor: actor).call }
      .to raise_error(ArgumentError, /duplicate source line/)
  end

  it "rejects employee or summary totals that disagree with exact source lines" do
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    malformed = response.deep_dup
    malformed["employees"][0]["regular_hours"] = 9.0
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(malformed)
    expect { described_class.new(pay_period: pay_period, source: source, actor: actor).call }
      .to raise_error(ArgumentError, /inconsistent employee totals/)

    malformed = response.deep_dup
    malformed["summary"]["regular_hours"] = 9.0
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(malformed)
    expect { described_class.new(pay_period: pay_period, source: source, actor: actor).call }
      .to raise_error(ArgumentError, /inconsistent summary totals/)
  end

  it "rejects duplicate people or one time entry assigned to multiple people" do
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    malformed = response.deep_dup
    other = malformed["employees"].first.deep_dup
    other["source_user_id"] = "18"
    malformed["employees"] << other
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(malformed)
    expect { described_class.new(pay_period: pay_period, source: source, actor: actor).call }
      .to raise_error(ArgumentError, /duplicate employee identity/)

    other["source_user_uuid"] = SecureRandom.uuid
    other["adjustments"][0]["line_key"] = "current:other"
    expect { described_class.new(pay_period: pay_period, source: source, actor: actor).call }
      .to raise_error(ArgumentError, /one time entry to multiple employees/)
  end

  it "shows a negative AIRE correction as a blocking payroll review item" do
    correction = response.deep_dup
    adjustment = correction.fetch("employees").first.fetch("adjustments").first
    adjustment["total_hours"] = -2.0
    adjustment["regular_hours"] = -2.0
    correction.fetch("employees").first["total_hours"] = -2.0
    correction.fetch("employees").first["regular_hours"] = -2.0
    correction.fetch("summary")["total_hours"] = -2.0
    correction.fetch("summary")["regular_hours"] = -2.0
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(correction)

    import = described_class.new(pay_period: pay_period, source: source, actor: actor).call

    expect(import.processed_payload.fetch("ready")).to be(false)
    expect(import.processed_payload.dig("rows", 0, "warnings").pluck("code")).to include("negative_correction")
  end

  it "replaces a changed pre-pay snapshot without losing the old source evidence" do
    current_response = response
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review) { current_response }
    first = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    first_result = TimeTracking::ApplyImportService.new(import: first, mappings: [], applied_by: actor).call
    expect(first_result.fetch(:errors)).to be_empty
    item = pay_period.payroll_items.find_by!(employee: employee)
    expect(item.hours_worked.to_d).to eq(8)

    current_response = response.deep_dup
    current_response["generated_at"] = "2026-09-14T02:00:00Z"
    adjustment = current_response.fetch("employees").first.fetch("adjustments").first
    adjustment["source_time_entry_version"] = 3
    adjustment["total_hours"] = 6.0
    adjustment["regular_hours"] = 6.0
    current_response.fetch("employees").first["total_hours"] = 6.0
    current_response.fetch("employees").first["regular_hours"] = 6.0
    current_response.fetch("summary")["total_hours"] = 6.0
    current_response.fetch("summary")["regular_hours"] = 6.0

    expect { TimeTracking::LiveSnapshotVerifier.call!(import: first, actor: actor) }
      .to raise_error(ArgumentError, /AIRE hours changed/)

    replacement = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    result = TimeTracking::ApplyImportService.new(import: replacement, mappings: [], applied_by: actor).call

    expect(result.fetch(:errors)).to be_empty
    expect(first.reload.status).to eq("superseded")
    expect(replacement.reload.status).to eq("applied")
    expect(item.reload.hours_worked.to_d).to eq(6)
    expect(first.time_tracking_entry_allocations.sum(:regular_hours)).to eq(8)
    expect(replacement.time_tracking_entry_allocations.sum(:regular_hours)).to eq(6)

    current_response = response.deep_dup.merge("generated_at" => "2026-09-14T03:00:00Z")
    restored = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    expect(restored.id).not_to eq(first.id)
    restored_result = TimeTracking::ApplyImportService.new(import: restored, mappings: [], applied_by: actor).call
    expect(restored_result.fetch(:errors)).to be_empty
    expect(replacement.reload.status).to eq("superseded")
    expect(item.reload.hours_worked.to_d).to eq(8)
  end

  it "links the imported source entry to the exact payroll item for post-commit acknowledgement" do
    client = instance_double(TimeTracking::Client)
    allow(TimeTracking::Client).to receive(:new).with(source).and_return(client)
    allow(client).to receive(:payroll_cockpit_manual_review).and_return(response)
    import = described_class.new(pay_period: pay_period, source: source, actor: actor).call
    result = TimeTracking::ApplyImportService.new(import: import, mappings: [], applied_by: actor).call
    expect(result.fetch(:errors)).to be_empty

    allocation_ids = TimeTracking::ImportedEntryLinker.new(pay_period: pay_period, actor: actor).call!
    allocation = TimeTrackingManualAllocation.find(allocation_ids.sole)

    expect(allocation).to have_attributes(
      source_time_entry_id: "101", source_time_entry_version: 2,
      source_user_uuid: uuid, regular_hours: 8, overtime_hours: 0,
      status: "pending_commit"
    )
    expect(allocation.payroll_item).to eq(pay_period.payroll_items.find_by!(employee: employee))
    expect(TimeTracking::ImportedEntryLinker.new(pay_period: pay_period, actor: actor).call!).to eq([ allocation.id ])

    allocation.payroll_item.update!(hours_worked: 7)
    expect { TimeTracking::ImportedEntryLinker.new(pay_period: pay_period, actor: actor).call! }
      .to raise_error(ArgumentError, /Payroll hours changed/)
  end
end
