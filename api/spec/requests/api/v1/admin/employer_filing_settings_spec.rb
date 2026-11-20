# frozen_string_literal: true

require "rails_helper"
RSpec.describe "Employer filing settings", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, company: company, role: "admin") }
  before do
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::CompaniesController).to receive(:current_user).and_return(user)
  end

  it "persists every employer filing field through the client settings endpoint" do
    patch "/api/v1/admin/companies/#{company.id}", params: { company: { filing_contact_name: "New Contact", kind_of_employer: "T", employment_code: "F", establishment_number: "A001" } }
    expect(response).to have_http_status(:ok)
    expect(company.reload.attributes.slice("filing_contact_name", "kind_of_employer", "employment_code", "establishment_number")).to eq({ "filing_contact_name" => "New Contact", "kind_of_employer" => "T", "employment_code" => "F", "establishment_number" => "A001" })
    audit = AuditLog.where(action: "companies#update", record_id: company.id).last
    expect(audit.metadata["after_values"]).to include("filing_contact_name" => "New Contact", "kind_of_employer" => "T", "employment_code" => "F", "establishment_number" => "A001")
  end

  it "rejects unsupported territorial employment codes" do
    patch "/api/v1/admin/companies/#{company.id}", params: { company: { employment_code: "X" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(company.reload.employment_code).to eq("R")
  end
end
