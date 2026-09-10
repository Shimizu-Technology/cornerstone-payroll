# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Per-client time tracking settings", type: :request do
  let!(:company) { create(:company) }
  let!(:admin) { create(:user, company: company, role: "admin") }
  let!(:period) { create(:pay_period, company: company) }

  before do
    [ Api::V1::Admin::PayPeriodsController, Api::V1::Admin::TimeTrackingSourcesController,
     Api::V1::Admin::TimeTrackingImportsController, Api::V1::Admin::ChecksController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user).and_return(admin)
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  def summary
    get "/api/v1/admin/pay_periods/#{period.id}"
    expect(response).to have_http_status(:ok)
    response.parsed_body.fetch("pay_period").fetch("time_tracking")
  end

  it "keeps integration actions off for a client with no source, even if another client uses AIRE" do
    create(:time_tracking_source, source_type: "aire_services", company: create(:company))
    expect(summary).to eq("active_source_types" => [], "linked_aire_records" => [])
  end

  it "uses the saved client source enable/disable setting without a second feature flag" do
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    expect(summary.fetch("active_source_types")).to eq([ "aire_services" ])

    patch "/api/v1/admin/time_tracking_sources/#{source.id}", params: { time_tracking_source: { active: false } }
    expect(response).to have_http_status(:ok)
    expect(summary.fetch("active_source_types")).to eq([])

    patch "/api/v1/admin/time_tracking_sources/#{source.id}", params: { time_tracking_source: { active: true } }
    expect(response).to have_http_status(:ok)
    expect(summary.fetch("active_source_types")).to eq([ "aire_services" ])
  end

  it "distinguishes a non-AIRE integration" do
    create(:time_tracking_source, company: company, source_type: "cornerstone_tax")
    expect(summary.fetch("active_source_types")).to eq([ "cornerstone_tax" ])
  end

  it "retains capabilities in mutation responses while keeping them out of the payroll list" do
    create(:time_tracking_source, company: company, source_type: "aire_services")
    patch "/api/v1/admin/pay_periods/#{period.id}", params: { pay_period: { notes: "Updated payroll note" } }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("pay_period", "time_tracking", "active_source_types")).to eq([ "aire_services" ])
    get "/api/v1/admin/pay_periods"
    expect(response.parsed_body.fetch("pay_periods").first).not_to have_key("time_tracking")
  end

  it "returns saved applied AIRE evidence with no allocations after deactivation, excluding previews and credentials" do
    source = create(:time_tracking_source, company: company, source_type: "aire_services", active: false)
    applied = create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source,
                     status: "applied", applied_at: Time.current, raw_payload: { "private_raw_marker" => "never expose" },
                     reconciliation_exceptions: [ { "employee_name" => "Saved Employee", "total_difference_hours" => "0.05" } ])
    create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source, external_batch_checksum: "b" * 64)
    other_source = create(:time_tracking_source, company: create(:company), source_type: "aire_services")
    create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: other_source, status: "applied")
    custom_source = create(:time_tracking_source, company: company, source_type: "custom", active: false)
    create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: custom_source, status: "applied")

    expect(TimeTracking::Client).not_to receive(:new)
    result = summary
    expect(result.fetch("active_source_types")).to eq([])
    expect(result.fetch("linked_aire_records").map { |record| record.fetch("id") }).to eq([ applied.id ])
    record = result.fetch("linked_aire_records").first
    expect(record).to include("source_active" => false, "external_batch_checksum" => applied.external_batch_checksum)
    expect(record.fetch("reconciliation_exceptions")).to eq(applied.reconciliation_exceptions)
    expect(record.keys).not_to include("shared_secret", "base_url", "raw_payload", "processed_payload")
    expect(response.body).not_to include("private_raw_marker")
  end

  it "identifies linked checks individually instead of treating all checks as AIRE payments" do
    source = create(:time_tracking_source, company: company, source_type: "aire_services")
    employee = create(:employee, company: company)
    linked = create(:payroll_item, :with_check, pay_period: period, employee: employee)
    ordinary = create(:payroll_item, :with_check, pay_period: period, employee: create(:employee, company: company))
    import = create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source, status: "applied")
    TimeTrackingEntryAllocation.create!(company: company, time_tracking_source: source, time_tracking_import: import,
      pay_period: period, payroll_item: linked, employee: employee, source_user_id: "source-user", source_time_entry_id: "entry-1",
      line_key: "line-1", source_kind: "current", original_work_date: period.start_date,
      total_hours: 8, regular_hours: 8, overtime_hours: 0)
    period.update!(status: "committed")
    get "/api/v1/admin/pay_periods/#{period.id}/checks"
    expect(response).to have_http_status(:ok)
    checks = response.parsed_body.fetch("checks").index_by { |item| item.fetch("id") }
    expect(checks.fetch(linked.id).fetch("aire_linked")).to be(true)
    expect(checks.fetch(ordinary.id).fetch("aire_linked")).to be(false)
  end

  it "rejects applying a cached preview after its source is disabled" do
    source = create(:time_tracking_source, company: company, active: false)
    import = create(:time_tracking_import, pay_period: period, time_tracking_source: source)
    expect(TimeTracking::Client).not_to receive(:new)
    post "/api/v1/admin/pay_periods/#{period.id}/apply_time_tracking_import", params: { import_id: import.id, mappings: [] }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Time tracking source is inactive")
    expect(import.reload.status).to eq("previewed")
    expect(period.payroll_items.count).to eq(0)
  end

  it "rejects linking a cached finalized batch after its source is disabled" do
    period.update!(status: "committed")
    source = create(:time_tracking_source, company: company, source_type: "aire_services", active: false)
    import = create(:time_tracking_import, :finalized_aire_batch, pay_period: period, time_tracking_source: source)
    post "/api/v1/admin/pay_periods/#{period.id}/reconcile_time_tracking_import",
         params: { import_id: import.id, mappings: [], reconciliation_note: "Reviewed the saved payroll." }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to eq("Time tracking source is inactive")
    expect(import.reload.status).to eq("previewed")
    expect(import.reconciled_at).to be_nil
  end
end
