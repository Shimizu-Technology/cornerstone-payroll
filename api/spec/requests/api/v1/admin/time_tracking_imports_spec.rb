# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::TimeTrackingImports", type: :request do
  let!(:company) { create(:company) }
  let!(:admin_user) { create(:user, company: company, role: "admin") }
  let!(:pay_period) { create(:pay_period, company: company) }
  let!(:source) do
    TimeTrackingSource.create!(
      company: company,
      name: "AIRE Services",
      source_type: "aire_services",
      base_url: "https://aire.example.com",
      shared_secret: "secret"
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::TimeTrackingImportsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::TimeTrackingImportsController).to receive(:current_company_id).and_return(company.id)
  end

  describe "POST /api/v1/admin/pay_periods/:id/preview_time_tracking_import" do
    it "loads the member pay period from the routed id parameter" do
      import = instance_double(
        TimeTrackingImport,
        id: 123,
        status: "previewed",
        time_tracking_source_id: source.id,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        warnings: [],
        processed_payload: { "rows" => [] },
        external_batch_id: nil,
        external_batch_checksum: nil,
        contract_version: nil,
        source_cutoff_at: nil,
        applied_at: nil,
        reconciled_at: nil,
        reconciliation_note: nil,
        reconciliation_exceptions: [],
        source_processing_status: nil,
        source_processing_synced_at: nil,
        source_processing_sync_error: nil
      )

      expect(TimeTracking::ImportPreviewService).to receive(:new).with(
        pay_period: pay_period,
        source: source,
        start_date: "2026-05-04",
        end_date: "2026-05-17"
      ).and_return(instance_double(TimeTracking::ImportPreviewService, call: import))

      post "/api/v1/admin/pay_periods/#{pay_period.id}/preview_time_tracking_import",
           params: {
             source_id: source.id,
             start_date: "2026-05-04",
             end_date: "2026-05-17"
           },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("import", "id")).to eq(123)
      expect(json.fetch("import")).to include(
        "applied_at" => nil,
        "source_processing_status" => nil,
        "source_processing_synced_at" => nil,
        "source_processing_sync_error" => nil
      )
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/apply_time_tracking_import" do
    it "loads the member pay period from the routed id parameter" do
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("payload"),
        raw_payload: {},
        processed_payload: { "rows" => [] },
        warnings: []
      )

      expect(TimeTracking::ApplyImportService).to receive(:new).with(
        import: import,
        mappings: [],
        applied_by: admin_user,
        acknowledge_negative_adjustments: nil,
        negative_adjustment_note: nil
      ).and_return(
        instance_double(TimeTracking::ApplyImportService, call: { applied: [], skipped: [], errors: [] })
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_time_tracking_import",
           params: {
             import_id: import.id,
             mappings: []
           },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("import", "id")).to eq(import.id)
      expect(json.dig("results", "errors")).to eq([])
    end

    it "returns 422 when permanent AIRE identities conflict" do
      import = TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("identity-conflict"),
        raw_payload: {},
        processed_payload: { "rows" => [] },
        warnings: []
      )
      service = instance_double(TimeTracking::ApplyImportService)
      allow(TimeTracking::ApplyImportService).to receive(:new).and_return(service)
      allow(service).to receive(:call).and_raise(
        TimeTrackingEmployeeMapping::IdentityConflict,
        "AIRE staff identity conflicts with two saved payroll mappings"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/apply_time_tracking_import",
           params: { import_id: import.id, mappings: [] },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json.fetch("error")).to match(/identity conflicts/)
    end
  end

  describe "POST /api/v1/admin/pay_periods/:id/reconcile_time_tracking_import" do
    let!(:import) do
      TimeTrackingImport.create!(
        pay_period: pay_period,
        time_tracking_source: source,
        start_date: pay_period.start_date,
        end_date: pay_period.end_date,
        fetch_start_date: pay_period.start_date,
        fetch_end_date: pay_period.end_date,
        source_payload_hash: Digest::SHA256.hexdigest("reconciliation"),
        raw_payload: {},
        processed_payload: { "rows" => [] },
        warnings: []
      )
    end

    it "passes mappings and the audit note to historical reconciliation" do
      service = instance_double(
        TimeTracking::ReconcileCommittedImportService,
        call: { reconciled: [ { employee_id: 42 } ], errors: [] }
      )
      expect(TimeTracking::ReconcileCommittedImportService).to receive(:new) do |**arguments|
        expect(arguments.except(:mappings)).to eq(
          import: import,
          reconciled_by: admin_user,
          reconciliation_note: "Compared with the signed payroll register"
        )
        expect(arguments.fetch(:mappings).map(&:to_h)).to eq(
          [ { "source_user_id" => "aire-7", "employee_id" => "42" } ]
        )
        service
      end

      post "/api/v1/admin/pay_periods/#{pay_period.id}/reconcile_time_tracking_import",
           params: {
             import_id: import.id,
             reconciliation_note: "Compared with the signed payroll register",
             mappings: [ { source_user_id: "aire-7", employee_id: 42 } ]
           },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json.dig("data", "results", "reconciled", 0, "employee_id")).to eq(42)
    end

    it "returns 422 for an identity conflict" do
      service = instance_double(TimeTracking::ReconcileCommittedImportService)
      allow(TimeTracking::ReconcileCommittedImportService).to receive(:new).and_return(service)
      allow(service).to receive(:call).and_raise(
        TimeTrackingEmployeeMapping::IdentityConflict,
        "AIRE staff identity conflicts with two saved payroll mappings"
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/reconcile_time_tracking_import",
           params: { import_id: import.id, reconciliation_note: "Compared with signed records", mappings: [] },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json.fetch("error")).to match(/identity conflicts/)
      expect(json.fetch("details")).to eq([])
    end

    it "returns the source row identity for an hours mismatch" do
      service = instance_double(TimeTracking::ReconcileCommittedImportService)
      allow(TimeTracking::ReconcileCommittedImportService).to receive(:new).and_return(service)
      allow(service).to receive(:call).and_raise(
        TimeTracking::ReconcileCommittedImportService::RowMismatch.new(
          "Employee does not reconcile",
          source_user_id: "aire-7",
          employee_id: 42
        )
      )

      post "/api/v1/admin/pay_periods/#{pay_period.id}/reconcile_time_tracking_import",
           params: { import_id: import.id, reconciliation_note: "Compared with signed records", mappings: [] },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json).to include("error" => "Employee does not reconcile", "details" => [])
      expect(json.fetch("data")).to eq("source_user_id" => "aire-7", "employee_id" => 42)
    end

    it "returns 404 for an unknown import" do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/reconcile_time_tracking_import",
           params: { import_id: import.id + 10_000, reconciliation_note: "Compared with signed records", mappings: [] },
           headers: { "X-Company-Id" => company.id.to_s }

      expect(response).to have_http_status(:not_found)
      json = JSON.parse(response.body)
      expect(json.fetch("error")).to eq("Time tracking import not found")
      expect(json.fetch("details")).to eq([])
    end
  end
end
