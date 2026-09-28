# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Finance organization context", type: :request do
  let!(:home_company) { create(:company) }
  let!(:other_company) { create(:company, organization: create(:organization, name: "Shimizu Technology LLC")) }
  let!(:platform_user) { create(:user, role: "super_admin", company: home_company, organization: home_company.organization) }

  before do
    allow_any_instance_of(Api::V1::Admin::InvoicesController).to receive(:current_user).and_return(platform_user)
  end

  it "uses an explicit organization even when the selected payroll company is elsewhere" do
    invoice = create(:invoice, :with_line_item, company: other_company)

    get "/api/v1/admin/invoices", headers: { "X-Organization-Id" => other_company.organization_id.to_s }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("invoices").map { |row| row.fetch("id") }).to include(invoice.id)
  end

  it "rejects a mismatched or nonexistent payroll company instead of falling back" do
    get "/api/v1/admin/invoices", headers: {
      "X-Organization-Id" => other_company.organization_id.to_s,
      "X-Company-Id" => home_company.id.to_s
    }
    expect(response).to have_http_status(:unprocessable_entity)

    get "/api/v1/admin/invoices", headers: { "X-Company-Id" => "999999999" }
    expect(response).to have_http_status(:not_found)
  end

  it "rejects an invalid organization rather than using the home organization" do
    get "/api/v1/admin/invoices", headers: { "X-Organization-Id" => "invalid" }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "does not allow an organization admin to select another organization" do
    admin = create(:user, role: "admin", company: home_company, organization: home_company.organization)
    allow_any_instance_of(Api::V1::Admin::InvoicesController).to receive(:current_user).and_return(admin)

    get "/api/v1/admin/invoices", headers: { "X-Organization-Id" => other_company.organization_id.to_s }
    expect(response).to have_http_status(:forbidden)
  end
end
