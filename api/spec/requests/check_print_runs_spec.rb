# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Check print runs", type: :request do
  let(:company) { create(:company) }
  let(:admin_user) { create(:user, company: company, organization: company.organization) }
  let(:pay_period) { create(:pay_period, :committed, company: company) }

  before do
    allow_any_instance_of(Api::V1::Admin::CheckPrintRunsController)
      .to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::CheckPrintRunsController)
      .to receive(:current_user).and_return(admin_user)
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
end
