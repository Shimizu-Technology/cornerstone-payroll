# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Form500s", type: :request do
  let!(:company) do
    create(:company,
      name: "Form 500 Co",
      ein: "66-1234567",
      address_line1: "123 Marine Dr",
      city: "Tamuning",
      state: "GU",
      zip: "96913")
  end
  let!(:user) { create(:user, company: company, role: "admin", email: "form500@example.com") }
  let!(:client_user) { create(:user, company: company, role: "client", email: "portal-form500@example.com") }
  let!(:employee) { create(:employee, company: company) }
  let!(:pay_period) do
    create(:pay_period, :committed,
      company: company,
      start_date: Date.new(2026, 4, 20),
      end_date: Date.new(2026, 5, 3),
      pay_date: Date.new(2026, 5, 6))
  end

  before do
    CompanyAssignment.create!(user: user, company: company)
    CompanyAssignment.create!(user: client_user, company: company)
    create(:payroll_item,
      pay_period: pay_period,
      employee: employee,
      company: company,
      gross_pay: 1000.0,
      net_pay: 840.0,
      withholding_tax: 125.4,
      social_security_tax: 62.0,
      medicare_tax: 14.5)

    allow_any_instance_of(Api::V1::Form500sController).to receive(:current_user).and_return(user)
    allow_any_instance_of(Api::V1::Form500sController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Form500sController).to receive(:current_company).and_return(company)
  end

  it "returns prefilled defaults, persists edits, and renders preview/download PDFs" do
    get "/api/v1/form_500s/defaults", params: { pay_period_id: pay_period.id }

    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("data")
    expect(data).to include(
      "company_name" => company.name,
      "company_address_line1" => "123 Marine Dr",
      "company_address_line2" => "",
      "company_city" => "Tamuning",
      "company_state" => "GU",
      "company_zip" => "96913",
      "employer_identification_number" => "66-1234567",
      "tax_year" => "2026",
      "tax_period_quarter" => 2,
      "total_taxes_dollars" => "125",
      "total_taxes_cents" => "40"
    )

    post "/api/v1/form_500s/save", params: {
      form_500: data.merge(
        pay_period_id: pay_period.id,
        notes: "Prepared for ACH batch",
        total_taxes_dollars: "130"
      )
    }

    expect(response).to have_http_status(:ok)
    expect(pay_period.reload.form500_filing).to be_present
    expect(pay_period.form500_filing.fields).to include(
      "notes" => "Prepared for ACH batch",
      "total_taxes_dollars" => "130"
    )

    post "/api/v1/form_500s/preview", params: { form_500: data.merge(pay_period_id: pay_period.id) }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Type"]).to include("application/pdf")
    expect(response.body).to start_with("%PDF")

    post "/api/v1/form_500s/download", params: { form_500: data.merge(pay_period_id: pay_period.id) }
    expect(response).to have_http_status(:ok)
    expect(response.headers["Content-Disposition"]).to include("attachment")
    expect(response.body).to start_with("%PDF")
  end

  it "prefers current company defaults when an older saved filing has blank identity fields" do
    pay_period.create_form500_filing!(
      company: company,
      created_by: user,
      updated_by: user,
      fields: {
        company_name: "",
        company_address_line1: "",
        company_address_line2: "",
        company_city: "",
        company_state: "",
        company_zip: "",
        employer_identification_number: "",
        tax_year: "2026",
        tax_period_quarter: 4,
        total_taxes_dollars: "125",
        total_taxes_cents: "40"
      }
    )

    get "/api/v1/form_500s/defaults", params: { pay_period_id: pay_period.id }

    expect(response).to have_http_status(:ok)
    data = response.parsed_body.fetch("data")
    expect(data).to include(
      "company_name" => company.name,
      "company_address_line1" => "123 Marine Dr",
      "company_address_line2" => "",
      "company_city" => "Tamuning",
      "company_state" => "GU",
      "company_zip" => "96913",
      "employer_identification_number" => "66-1234567",
      "tax_period_quarter" => 4
    )
  end

  it "returns 404 instead of double-rendering for a missing pay period" do
    get "/api/v1/form_500s/defaults", params: { pay_period_id: pay_period.id + 9999 }

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body).to eq("error" => "Pay period not found")
  end

  it "forbids client users from accessing Form 500 endpoints" do
    allow_any_instance_of(Api::V1::Form500sController).to receive(:current_user).and_return(client_user)

    get "/api/v1/form_500s/defaults", params: { pay_period_id: pay_period.id }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body).to eq("error" => "Access denied")
  end
end
