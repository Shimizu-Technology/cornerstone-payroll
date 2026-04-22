# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::PayStubs", type: :request do
  let!(:company) { create(:company, name: "Staff HQ") }
  let!(:department) { create(:department, company: company) }
  let!(:employee) do
    create(
      :employee,
      company: company,
      department: department,
      first_name: "Pat",
      last_name: "Stub"
    )
  end
  let!(:pay_period) { create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 4, 15)) }
  let!(:payroll_item) do
    create(
      :payroll_item,
      pay_period: pay_period,
      employee: employee,
      gross_pay: 1200.0,
      net_pay: 960.0
    )
  end
  let!(:admin_user) do
    User.create!(
      company: company,
      email: "paystubs-admin@example.com",
      name: "Pay Stubs Admin",
      role: "admin",
      active: true
    )
  end

  let(:storage) { instance_double(R2StorageService) }
  let(:new_key) do
    "paystubs/2026/company_#{company.id}/employee_#{employee.id}/payroll_item_#{payroll_item.id}_20260415.pdf"
  end
  let(:legacy_key) do
    "paystubs/2026/#{employee.id}/paystub_20260415.pdf"
  end

  before do
    allow_any_instance_of(Api::V1::Admin::PayStubsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::PayStubsController).to receive(:current_user_id).and_return(admin_user.id)
    allow_any_instance_of(Api::V1::Admin::PayStubsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::PayStubsController).to receive(:r2_configured?).and_return(true)
    allow(R2StorageService).to receive(:new).and_return(storage)
    allow(storage).to receive(:exists?) do |key|
      key == legacy_key
    end
  end

  describe "GET /api/v1/admin/pay_stubs/:id" do
    it "reports legacy-stored pay stubs as generated" do
      get "/api/v1/admin/pay_stubs/#{payroll_item.id}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("pay_stub")).to include(
        "generated" => true,
        "storage_key" => legacy_key
      )
    end
  end

  describe "GET /api/v1/admin/pay_stubs/:id/download" do
    it "downloads the legacy R2 object when the new key is absent" do
      allow(storage).to receive(:download).with(legacy_key).and_return("%PDF-legacy")

      get "/api/v1/admin/pay_stubs/#{payroll_item.id}/download"

      expect(response).to have_http_status(:ok)
      expect(response.body).to eq("%PDF-legacy")
      expect(response.headers["Content-Type"]).to include("application/pdf")
    end
  end
end
