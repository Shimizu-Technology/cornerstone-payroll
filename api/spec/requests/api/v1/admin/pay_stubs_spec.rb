# frozen_string_literal: true

require "rails_helper"
require "combine_pdf"

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
  let!(:second_employee) do
    create(
      :employee,
      company: company,
      department: department,
      first_name: "Alex",
      last_name: "Ledger"
    )
  end
  let!(:second_payroll_item) do
    create(
      :payroll_item,
      pay_period: pay_period,
      employee: second_employee,
      gross_pay: 900.0,
      net_pay: 720.0
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

  describe "POST /api/v1/admin/pay_stubs/batch_pdf" do
    before do
      allow_any_instance_of(Api::V1::Admin::PayStubsController).to receive(:r2_configured?).and_return(false)
    end

    it "downloads one combined plain-paper pay stub PDF for a pay period" do
      post "/api/v1/admin/pay_stubs/batch_pdf", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Type"]).to include("application/pdf")
      expect(response.headers["Content-Disposition"]).to include("paystubs_2026-04-15.pdf")
      expect(response.body).to start_with("%PDF")
      expect(CombinePDF.parse(response.body).pages.count).to eq(2)
    end

    it "skips payroll items with no pay activity when printing all pay stubs" do
      unpaid_employee = create(:employee, company: company, department: department, first_name: "Una", last_name: "Paid")
      create(:payroll_item, pay_period: pay_period, employee: unpaid_employee, gross_pay: 0, net_pay: 0, check_number: nil)

      post "/api/v1/admin/pay_stubs/batch_pdf", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      expect(CombinePDF.parse(response.body).pages.count).to eq(2)
    end

    it "limits the combined PDF to selected payroll items" do
      post "/api/v1/admin/pay_stubs/batch_pdf", params: {
        pay_period_id: pay_period.id,
        payroll_item_ids: [ second_payroll_item.id ]
      }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("selected_paystubs_2026-04-15.pdf")
      expect(CombinePDF.parse(response.body).pages.count).to eq(1)
    end

    it "rejects selected payroll items outside the pay period" do
      other_period = create(:pay_period, :committed, company: company, pay_date: Date.new(2026, 4, 30))
      other_item = create(:payroll_item, pay_period: other_period, employee: employee)

      post "/api/v1/admin/pay_stubs/batch_pdf", params: {
        pay_period_id: pay_period.id,
        payroll_item_ids: [ other_item.id ]
      }

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body.fetch("error")).to eq("One or more selected pay stubs were not found")
    end

    it "reports selected unpaid payroll items clearly" do
      unpaid_employee = create(:employee, company: company, department: department, first_name: "Una", last_name: "Paid")
      unpaid_item = create(:payroll_item, pay_period: pay_period, employee: unpaid_employee, gross_pay: 0, net_pay: 0, check_number: nil)

      post "/api/v1/admin/pay_stubs/batch_pdf", params: {
        pay_period_id: pay_period.id,
        payroll_item_ids: [ unpaid_item.id ]
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Selected employees were not paid in this pay period")
      expect(response.parsed_body.fetch("details")).to include(unpaid_employee.full_name)
    end

    it "reports selected voided payroll items clearly" do
      voided_employee = create(
        :employee,
        company: company,
        department: department,
        first_name: "Vera",
        last_name: "Voided"
      )
      voided_item = create(
        :payroll_item,
        :voided,
        pay_period: pay_period,
        employee: voided_employee,
        gross_pay: 1200.0,
        net_pay: 960.0
      )

      post "/api/v1/admin/pay_stubs/batch_pdf", params: {
        pay_period_id: pay_period.id,
        payroll_item_ids: [ voided_item.id ]
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Voided checks do not have printable pay stubs")
      expect(response.parsed_body.fetch("details")).to include(voided_employee.full_name)
    end
  end
end
