# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Check print runs", type: :request do
  let(:company) { create(:company) }
  let(:admin_user) { create(:user, company: company, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }
  let(:print_run) do
    CheckPrintRun.create!(
      company: company,
      pay_period: pay_period,
      created_by: admin_user,
      status: "generated",
      check_stock_type: company.check_stock_type,
      starting_slot: 1,
      selected_count: 1,
      manifest: [ { "source_type" => "payroll_item", "source_id" => 123 } ],
      storage_key: "check-print-runs/spec-package.pdf",
      filename: "spec-package.pdf",
      sha256: "a" * 64,
      byte_size: 100,
      generated_at: Time.current
    )
  end

  before do
    allow_any_instance_of(Api::V1::Admin::CheckPrintRunsController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::CheckPrintRunsController)
      .to receive(:current_user).and_return(admin_user)
  end

  it "returns a structured conflict when the pay period is no longer printable" do
    pay_period.update!(status: "calculated", committed_at: nil)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_queue"

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body).to eq(
      "error" => "Checks are only available for committed pay periods"
    )
  end

  it "returns a structured retryable response when package generation has an infrastructure failure" do
    service = instance_double(CheckPrintRunGenerationService)
    allow(CheckPrintRunGenerationService).to receive(:new).and_return(service)
    allow(service).to receive(:call).and_raise(R2StorageService::UploadError, "private storage detail")
    allow(Rails.logger).to receive(:error)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_runs",
      params: { payroll_item_ids: [ 123 ], non_employee_check_ids: [], starting_slot: 1 }

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq(
      "error" => "The check package could not be generated. No checks were marked printed. Please try again."
    )
    expect(response.body).not_to include("private storage detail")
    expect(Rails.logger).to have_received(:error).with(include(
      "[check_print_runs#create]",
      "R2StorageService::UploadError: private storage detail"
    ))
  end

  it "does not expose storage details when a generated package download fails" do
    allow_any_instance_of(R2StorageService)
      .to receive(:download).and_raise(R2StorageService::DownloadError, "private R2 endpoint detail")
    allow(Rails.logger).to receive(:error)

    get "/api/v1/admin/check_print_runs/#{print_run.id}/pdf"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq(
      "error" => "The generated check package could not be downloaded. Please try again."
    )
    expect(response.body).not_to include("private R2 endpoint detail")
    expect(Rails.logger).to have_received(:error).with(include(
      "[check_print_runs#pdf]",
      "R2StorageService::DownloadError: private R2 endpoint detail"
    ))
  end

  it "returns a structured retryable response when print confirmation has an infrastructure failure" do
    service = instance_double(CheckPrintRunConfirmationService)
    allow(CheckPrintRunConfirmationService).to receive(:new).and_return(service)
    allow(service).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished, "private database detail")
    allow(Rails.logger).to receive(:error)

    post "/api/v1/admin/check_print_runs/#{print_run.id}/confirm"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq(
      "error" => "Print confirmation could not be recorded. No check print statuses were changed. Please try again."
    )
    expect(response.body).not_to include("private database detail")
    expect(Rails.logger).to have_received(:error).with(include(
      "[check_print_runs#confirm]",
      "ActiveRecord::ConnectionNotEstablished: private database detail"
    ))
  end
end
