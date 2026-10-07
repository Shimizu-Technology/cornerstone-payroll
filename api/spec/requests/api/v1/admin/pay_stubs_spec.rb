# frozen_string_literal: true

require "rails_helper"
require "combine_pdf"
require "pdf/reader"

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

  describe "current statement eligibility for individual downloads" do
    it "generates a fresh zero-net statement instead of reusing an old cached payment label" do
      payroll_item.update!(net_pay: 0)
      expect(storage).not_to receive(:download)

      get "/api/v1/admin/pay_stubs/#{payroll_item.id}/download"

      expect(response).to have_http_status(:ok)
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ")
      expect(text).to include("Earnings statement only - no payment issued")
    end

    it "does not generate a current statement for voided or no-activity records" do
      payroll_item.update!(voided: true, voided_at: Time.current, void_reason: "Cancelled test payroll")
      get "/api/v1/admin/pay_stubs/#{payroll_item.id}/download"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("Voided payroll")

      payroll_item.update!(voided: false, gross_pay: 0, net_pay: 0)
      get "/api/v1/admin/pay_stubs/#{payroll_item.id}/download"
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("no earnings-statement activity")
    end
  end

  describe "POST /api/v1/admin/pay_stubs/batch_generate" do
    before do
      allow_any_instance_of(Api::V1::Admin::PayStubsController).to receive(:r2_configured?).and_return(false)
    end

    it "reports skipped payroll items with no pay activity without counting voided checks" do
      unpaid_employee = create(:employee, company: company, department: department, first_name: "Una", last_name: "Paid")
      voided_employee = create(:employee, company: company, department: department, first_name: "Vera", last_name: "Voided")
      create(:payroll_item, pay_period: pay_period, employee: unpaid_employee, gross_pay: 0, net_pay: 0, check_number: nil)
      create(:payroll_item, :voided, pay_period: pay_period, employee: voided_employee, gross_pay: 1200, net_pay: 960)

      post "/api/v1/admin/pay_stubs/batch_generate", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.fetch("total")).to eq(3)
      expect(response.parsed_body.fetch("generated")).to eq(2)
      expect(response.parsed_body.fetch("skipped")).to eq(1)
      expect(response.parsed_body.fetch("errors")).to eq(0)
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
      expect(response.headers["X-Pay-Stubs-Generated"]).to eq("2")
      expect(response.headers["X-Pay-Stubs-Skipped"]).to eq("1")
      expect(CombinePDF.parse(response.body).pages.count).to eq(2)
    end

    it "includes wage-positive zero-net and reimbursement-only statements exactly once without issuing payments" do
      zero_employee = create(:employee, company: company, department: department, first_name: "Avery", last_name: "Example")
      zero_item = create(:payroll_item, pay_period: pay_period, employee: zero_employee,
        hours_worked: 21.37, gross_pay: 197.67, total_deductions: 197.67,
        social_security_tax: 12.26, medicare_tax: 2.87, loan_payment: 182.54, net_pay: 0)
      reimb_employee = create(:employee, company: company, department: department, first_name: "Casey", last_name: "Reimbursement")
      create(:payroll_item, pay_period: pay_period, employee: reimb_employee,
        gross_pay: 0, non_taxable_pay: 75, net_pay: 75, payment_delivery_method: "direct_deposit")
      previous_attributes = zero_item.attributes
      next_number = company.next_check_number

      post "/api/v1/admin/pay_stubs/batch_pdf", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Pay-Stubs-Generated"]).to eq("4")
      pdf_pages = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text)
      expect(pdf_pages.count { |text| text.include?("Avery Example") }).to eq(1)
      zero_text = pdf_pages.find { |text| text.include?("Avery Example") }
      expect(zero_text).to include("197.67", "182.54", "21.37", "$0.00")
      expect(zero_item.reload.attributes).to eq(previous_attributes)
      expect(company.reload.next_check_number).to eq(next_number)
    end

    it "prints a selected statement-only row and negative correction activity" do
      payroll_item.update!(net_pay: 0)
      correction_employee = create(:employee, company: company, department: department, first_name: "Casey", last_name: "Correction")
      correction = create(:payroll_item, pay_period: pay_period, employee: correction_employee,
        correction_for_payroll_item: payroll_item, hours_worked: 0, gross_pay: -100, net_pay: -80,
        total_deductions: -20, withholding_tax: -20)

      post "/api/v1/admin/pay_stubs/batch_pdf", params: {
        pay_period_id: pay_period.id, payroll_item_ids: [ payroll_item.id, correction.id, payroll_item.id ]
      }

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Pay-Stubs-Generated"]).to eq("2")
      expect(CombinePDF.parse(response.body).pages.count).to eq(2)
      expect(PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ")).to include("Casey Correction", "-100.00")
    end

    it "does not expose a legacy-excluded row through an explicit selection" do
      empty_employee = create(:employee, company: company, department: department)
      empty = create(:payroll_item, pay_period: pay_period, employee: empty_employee, hours_worked: 0)
      PayrollItemLegacyDisposition.create!(payroll_item: empty, company: company,
        created_by: admin_user, reason: "verified_empty_legacy_item", evidence_digest: "a" * 64)

      post "/api/v1/admin/pay_stubs/batch_pdf", params: {
        pay_period_id: pay_period.id, payroll_item_ids: [ empty.id ]
      }

      expect(response).to have_http_status(:not_found)
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
      expect(response.parsed_body.fetch("error")).to eq("Selected employees have no earnings-statement activity in this pay period")
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

  describe "POST /api/v1/admin/pay_stubs/direct_deposit_stubs_pdf" do
    let!(:deposit_employee) { create(:employee, company: company, department: department, first_name: "Dina", last_name: "Deposit", payment_delivery_method: "direct_deposit") }
    let!(:deposit_item) do
      create(:payroll_item, pay_period: pay_period, employee: deposit_employee,
        payment_delivery_method: "direct_deposit", check_number: nil, gross_pay: 600, net_pay: 500)
    end

    it "prints only direct-deposit employees on the existing earnings stub" do
      post "/api/v1/admin/pay_stubs/direct_deposit_stubs_pdf", params: { pay_period_id: pay_period.id }

      expect(response).to have_http_status(:ok)
      expect(response.headers["Content-Disposition"]).to include("direct_deposit_stubs_2026-04-15.pdf")
      expect(CombinePDF.parse(response.body).pages.count).to eq(1)
      text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join(" ")
      expect(text).to include("EARNINGS STATEMENT", "Dina Deposit", "Direct deposit")
      expect(text).not_to include("Pat Stub", "Alex Ledger")
    end

    it "keeps statement-only deposits in all statements, separate from positive-net deposit printing" do
      deposit_item.update!(net_pay: 0)

      post "/api/v1/admin/pay_stubs/direct_deposit_stubs_pdf", params: { pay_period_id: pay_period.id }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("No direct-deposit")

      post "/api/v1/admin/pay_stubs/batch_pdf", params: {
        pay_period_id: pay_period.id, payroll_item_ids: [ deposit_item.id ]
      }
      expect(response).to have_http_status(:ok)
      expect(response.headers["X-Pay-Stubs-Generated"]).to eq("1")
    end

    it "names each incompatible selection and explains how to print their statements" do
      deposit_item.update!(net_pay: 0)

      post "/api/v1/admin/pay_stubs/direct_deposit_stubs_pdf", params: {
        pay_period_id: pay_period.id, payroll_item_ids: [ deposit_item.id, payroll_item.id ]
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to eq("Select only direct-deposit employees with a positive payment")
      expect(response.parsed_body.fetch("details")).to include("Dina Deposit", "Pat Stub", "Remove", "use all earnings statements")
      expect(response.parsed_body.fetch("details")).not_to include("Alex Ledger")
    end

    it "rejects a paper-check item in an explicit stub selection" do
      post "/api/v1/admin/pay_stubs/direct_deposit_stubs_pdf", params: {
        pay_period_id: pay_period.id, payroll_item_ids: [ deposit_item.id, payroll_item.id ]
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to include("only direct-deposit")
    end
  end
end
