# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Check print generations", type: :request do
  let(:company) { create(:company, check_stock_type: "top_check") }
  let(:user) { create(:user, company:, organization: company.organization, role: "accountant") }
  let(:pay_period) { create(:pay_period, :committed, company:) }
  let(:employee) { create(:employee, company:) }
  let(:payroll_item) do
    create(:payroll_item, :with_check, company:, pay_period:, employee:, check_number: "7001")
  end
  let(:printer_profile) do
    PrinterProfile.create!(
      organization: company.organization,
      created_by: user,
      name: "Payroll Office",
      check_stock_type: company.check_stock_type,
      check_offset_x: 0,
      check_offset_y: 0
    )
  end
  let(:request_params) do
    {
      idempotency_key: "generation-request-1",
      payroll_item_ids: [ payroll_item.id ],
      non_employee_check_ids: [],
      starting_slot: 1,
      printer_profile_id: printer_profile.id,
      printer_profile_lock_version: printer_profile.lock_version
    }
  end

  before do
    allow_any_instance_of(Api::V1::Admin::CheckPrintGenerationsController)
      .to receive(:current_user).and_return(user)
    allow_any_instance_of(Api::V1::Admin::CheckPrintGenerationsController)
      .to receive(:current_company_id).and_return(company.id)
    allow(CheckPrintGenerationJob).to receive(:perform_later)
  end

  it "accepts a generation request and enqueues it exactly once" do
    expect {
      post "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations",
        params: request_params,
        headers: { "REMOTE_ADDR" => "203.0.113.42" }
    }.to change(CheckPrintGeneration, :count).by(1)

    expect(response).to have_http_status(:accepted)
    generation = CheckPrintGeneration.sole
    expect(generation.request_ip).to eq("203.0.113.42")
    expect(CheckPrintGenerationJob).to have_received(:perform_later).once.with(generation.id)
    expect(response.parsed_body.fetch("check_print_generation")).to include(
      "id" => generation.id,
      "status" => "queued",
      "phase" => "queued",
      "completed_items" => 0,
      "total_items" => 1
    )
  end

  it "returns the original generation for an identical idempotent retry" do
    2.times do
      post "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations", params: request_params
      expect(response).to have_http_status(:accepted)
    end

    expect(CheckPrintGeneration.count).to eq(1)
    expect(CheckPrintGenerationJob).to have_received(:perform_later).once
  end

  it "rejects reuse of an idempotency key for a different selection" do
    post "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations", params: request_params
    post "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations",
      params: request_params.merge(starting_slot: 2)

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to include("different check selection")
    expect(CheckPrintGeneration.count).to eq(1)
    expect(CheckPrintGenerationJob).to have_received(:perform_later).once
  end

  it "returns only the current operator's active generation for this pay period" do
    visible = CheckPrintGeneration.create!(
      company:, pay_period:, requested_by: user, printer_profile:,
      idempotency_key: "visible", request_digest: "a" * 64,
      payroll_item_ids: [ payroll_item.id ], non_employee_check_ids: [],
      printer_profile_lock_version: printer_profile.lock_version,
      starting_slot: 1, total_items: 1
    )
    other_user = create(:user, company:, organization: company.organization)
    CheckPrintGeneration.create!(
      company:, pay_period:, requested_by: other_user, printer_profile:,
      idempotency_key: "hidden", request_digest: "b" * 64,
      payroll_item_ids: [ payroll_item.id ], non_employee_check_ids: [],
      printer_profile_lock_version: printer_profile.lock_version,
      starting_slot: 1, total_items: 1
    )

    get "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations/active"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("check_print_generation", "id")).to eq(visible.id)
  end

  it "does not expose another operator's generation by id" do
    other_user = create(:user, company:, organization: company.organization)
    hidden = CheckPrintGeneration.create!(
      company:, pay_period:, requested_by: other_user, printer_profile:,
      idempotency_key: "hidden", request_digest: "b" * 64,
      payroll_item_ids: [ payroll_item.id ], non_employee_check_ids: [],
      printer_profile_lock_version: printer_profile.lock_version,
      starting_slot: 1, total_items: 1
    )

    get "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations/#{hidden.id}"

    expect(response).to have_http_status(:not_found)
  end

  it "does not accept a pay period or printer profile from another company" do
    other_company = create(:company)
    other_period = create(:pay_period, :committed, company: other_company)
    other_profile = PrinterProfile.create!(
      organization: other_company.organization,
      name: "Other Printer",
      check_stock_type: other_company.check_stock_type,
      check_offset_x: 0,
      check_offset_y: 0
    )

    post "/api/v1/admin/pay_periods/#{other_period.id}/check_print_generations", params: request_params
    expect(response).to have_http_status(:not_found)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations",
      params: request_params.merge(printer_profile_id: other_profile.id)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("error")).to include("active printer profile")
  end

  it "records a safe failed state when the queue cannot accept the job" do
    allow(CheckPrintGenerationJob).to receive(:perform_later)
      .and_raise(ActiveJob::EnqueueError, "private adapter detail")
    allow(Rails.logger).to receive(:error)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations", params: request_params

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).not_to include("private adapter detail")
    expect(CheckPrintGeneration.sole).to have_attributes(
      status: "failed",
      phase: "failed",
      error_code: "queue_unavailable"
    )
  end

  it "forbids client-portal users" do
    client_user = create(:user, company:, organization: company.organization, role: "client")
    allow_any_instance_of(Api::V1::Admin::CheckPrintGenerationsController)
      .to receive(:current_user).and_return(client_user)

    post "/api/v1/admin/pay_periods/#{pay_period.id}/check_print_generations", params: request_params

    expect(response).to have_http_status(:forbidden)
    expect(CheckPrintGeneration.count).to eq(0)
  end
end
