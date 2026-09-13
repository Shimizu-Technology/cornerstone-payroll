# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Admin::EmployeeDocumentRequirements", type: :request do
  let(:company) { create(:company) }
  let(:admin) { create(:user, company: company, role: "admin") }
  let(:employee) { create(:employee, company: company) }
  let(:document) { create(:client_document, company: company, employee: employee, uploaded_by: admin) }
  let(:requirement) do
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
    allow_any_instance_of(Api::V1::Admin::EmployeeDocumentRequirementsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::EmployeeDocumentRequirementsController).to receive(:current_company_id).and_return(company.id)
  end

  it "returns the employee checklist without storage keys" do
    requirement

    get "/api/v1/admin/employees/#{employee.id}/document_requirements"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").first).to include(
      "id" => requirement.id,
      "client_document_id" => document.id,
      "document_title" => document.title,
      "status" => "received"
    )
    expect(response.body).not_to include(document.file_key)
  end

  it "verifies a received document and records an audit event" do
    patch "/api/v1/admin/employees/#{employee.id}/document_requirements/#{requirement.id}", params: {
      document_requirement: {
        status: "verified",
        client_document_id: document.id,
        review_note: "Reviewed signed source against payroll setup.",
        lock_version: requirement.lock_version
      }
    }

    expect(response).to have_http_status(:ok), response.body
    expect(requirement.reload.status).to eq("verified")
    expect(AuditLog.where(action: "employee_document_requirements#update", record_id: requirement.id)).to exist
    expect(response.parsed_body.fetch("readiness")).to include("ready_for_payroll" => true)
    expect(response.parsed_body.dig("data", 0, "history", 0)).to include(
      "event_type" => "status_changed",
      "from_status" => "received",
      "to_status" => "verified",
      "document_title" => document.title,
      "actor_name" => admin.name
    )
  end

  it "rejects a stale browser update" do
    stale_version = requirement.lock_version
    requirement.update!(received_at: 1.minute.ago)

    patch "/api/v1/admin/employees/#{employee.id}/document_requirements/#{requirement.id}", params: {
      document_requirement: { status: "received", lock_version: stale_version }
    }

    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body.fetch("error")).to include("Refresh")
  end

  it "does not expose another company's requirement" do
    other_company = create(:company)
    other_employee = create(:employee, company: other_company)
    other_requirement = create(:employee_document_requirement, company: other_company, employee: other_employee)

    get "/api/v1/admin/employees/#{other_employee.id}/document_requirements"
    expect(response).to have_http_status(:not_found)

    patch "/api/v1/admin/employees/#{employee.id}/document_requirements/#{other_requirement.id}", params: {
      document_requirement: { status: "received", lock_version: other_requirement.lock_version }
    }
    expect(response).to have_http_status(:not_found)
  end
end
