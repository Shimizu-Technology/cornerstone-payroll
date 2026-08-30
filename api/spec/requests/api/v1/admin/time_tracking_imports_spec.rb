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
        applied_at: nil
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
      expect(response.parsed_body.dig("import", "id")).to eq(123)
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
      expect(response.parsed_body.dig("import", "id")).to eq(import.id)
      expect(response.parsed_body.dig("results", "errors")).to eq([])
    end
  end
end
