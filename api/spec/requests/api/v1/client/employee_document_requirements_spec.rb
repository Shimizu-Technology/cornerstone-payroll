# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::EmployeeDocumentRequirements", type: :request do
  let(:company) { create(:company) }
  let(:client_user) { create(:user, company: company, role: "client") }
  let(:employee) { create(:employee, company: company) }
  let(:document) do
    create(
      :client_document,
      company: company,
      employee: employee,
      uploaded_by: client_user,
      visible_to_client: false,
      file_key: "client_documents/private/never-expose.txt"
    )
  end
  let!(:requirement) do
    create(
      :employee_document_requirement,
      company: company,
      employee: employee,
      client_document: document,
      status: "received",
      received_at: Time.current
    )
  end

  before do
    allow_any_instance_of(Api::V1::Client::EmployeeDocumentRequirementsController).to receive(:current_company_id).and_return(company.id)
  end

  it "shows readiness without exposing a staff-only document or internal review note" do
    get "/api/v1/client/employees/#{employee.id}/document_requirements"

    expect(response).to have_http_status(:ok)
    row = response.parsed_body.fetch("data").first
    expect(row).to include("status" => "received", "document_attached" => true)
    expect(row["client_document_id"]).to be_nil
    expect(row["document_title"]).to be_nil
    expect(row["review_note"]).to be_nil
    expect(response.body).not_to include(document.file_key)
  end

  it "does not expose another company's employee checklist" do
    other_employee = create(:employee, company: create(:company))

    get "/api/v1/client/employees/#{other_employee.id}/document_requirements"

    expect(response).to have_http_status(:not_found)
  end
end
