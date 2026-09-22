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

  it "lists saved packages for the current pay period without exposing another client" do
    print_run.update!(
      status: "confirmed",
      confirmed_at: Time.current,
      confirmed_by: admin_user
    )
    other_company = create(:company)
    other_period = create(:pay_period, :committed, company: other_company)
    CheckPrintRun.create!(
      company: other_company,
      pay_period: other_period,
      status: "confirmed",
      check_stock_type: other_company.check_stock_type,
      starting_slot: 1,
      selected_count: 1,
      manifest: [ { "source_type" => "payroll_item", "source_id" => 999 } ],
      storage_key: "check-print-runs/other-package.pdf",
      filename: "other-package.pdf",
      sha256: "b" * 64,
      byte_size: 100,
      generated_at: Time.current,
      confirmed_at: Time.current
    )

    get "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_runs"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("check_print_runs").sole).to include(
      "id" => print_run.id,
      "confirmation_state" => "confirmed",
      "confirmation_issue" => nil
    )
  end

  it "marks an unconfirmed saved package stale when its check data changed" do
    employee = create(:employee, company: company)
    item = create(
      :payroll_item,
      company: company,
      pay_period: pay_period,
      employee: employee,
      net_pay: 500,
      check_number: "4101",
      check_print_count: 0,
      check_printed_at: nil
    )
    run = CheckPrintRun.create!(
      company: company,
      pay_period: pay_period,
      created_by: admin_user,
      status: "generated",
      check_stock_type: company.check_stock_type,
      starting_slot: 1,
      selected_count: 1,
      manifest: [ {
        "key" => "payroll_item:#{item.id}",
        "source_type" => "payroll_item",
        "source_id" => item.id,
        "check_number" => item.check_number,
        "payee" => employee.full_name,
        "amount" => "500.00",
        "source_updated_at" => item.updated_at.iso8601(6),
        "printed_at" => nil,
        "print_count" => 0
      } ],
      storage_key: "check-print-runs/stale-package.pdf",
      filename: "stale-package.pdf",
      sha256: "c" * 64,
      byte_size: 100,
      generated_at: Time.current
    )
    item.update_columns(net_pay: 501, updated_at: Time.current)

    get "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_runs"

    payload = response.parsed_body.fetch("check_print_runs").find { |saved| saved.fetch("id") == run.id }
    expect(payload).to include("confirmation_state" => "stale")
    expect(payload.fetch("confirmation_issue")).to include("different amount")
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

  it "returns the same sanitized response for an unexpected package download failure" do
    allow_any_instance_of(R2StorageService)
      .to receive(:download).and_raise(NoMethodError, "unexpected private implementation detail")
    allow(Rails.logger).to receive(:error)

    get "/api/v1/admin/check_print_runs/#{print_run.id}/pdf"

    expect(response).to have_http_status(:service_unavailable)
    expect(response.parsed_body).to eq(
      "error" => "The generated check package could not be downloaded. Please try again."
    )
    expect(response.body).not_to include("unexpected private implementation detail")
    expect(Rails.logger).to have_received(:error).with(include(
      "[check_print_runs#pdf]",
      "NoMethodError: unexpected private implementation detail"
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
