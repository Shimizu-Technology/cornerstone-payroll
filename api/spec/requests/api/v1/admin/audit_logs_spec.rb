require "rails_helper"

RSpec.describe "Api::V1::Admin::AuditLogs", type: :request do
  let!(:organization) { create(:organization, name: "Audit Firm") }
  let!(:company) { create(:company, organization: organization, name: "Audit Client") }
  let!(:admin) { create(:user, organization: organization, company: company, role: :admin, name: "Audit Admin") }
  let!(:foreign_organization) { create(:organization, name: "Other Firm") }
  let!(:foreign_company) { create(:company, organization: foreign_organization) }
  let!(:foreign_admin) { create(:user, organization: foreign_organization, company: foreign_company, role: :admin) }

  before do
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user).and_return(admin)
    allow_any_instance_of(Api::V1::Admin::AuditLogsController).to receive(:current_user_id).and_return(admin.id)
  end

  it "returns complete paginated organization history without leaking other organizations" do
    3.times do |index|
      AuditLog.record!(user: admin, organization_id: organization.id, action: "users#updated", record_type: "users", record_id: index + 1)
    end
    AuditLog.record!(user: foreign_admin, organization_id: foreign_organization.id, action: "users#updated", record_type: "users")

    get "/api/v1/admin/audit_logs", params: { page: 2, per_page: 2, sort_direction: "asc" }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.fetch("data").length).to eq(1)
    expect(response.parsed_body.fetch("meta")).to include("current_page" => 2, "per_page" => 2, "total_count" => 3, "total_pages" => 2)
    expect(response.parsed_body.fetch("data").pluck("organization_id")).to all(eq(organization.id))
  end

  it "exports filtered history as CSV and records the export" do
    AuditLog.record!(user: admin, organization_id: organization.id, action: "users#updated", record_type: "users", record_id: admin.id)

    expect {
      get "/api/v1/admin/audit_logs/export", params: { record_type: "users", record_id: admin.id }
    }.to change { AuditLog.where(action: "audit_logs#export").count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/csv")
    expect(response.body).to include("Audit Admin", "users#updated")
  end

  it "exports in the requested timestamp order and neutralizes spreadsheet formulas" do
    AuditLog.create!(
      user: admin,
      organization: organization,
      action: "users#created",
      record_type: "users",
      created_at: 1.day.ago
    )
    AuditLog.create!(
      user: admin,
      organization: organization,
      action: "users#updated",
      record_type: "users",
      subject_name: "=HYPERLINK(\"https://example.test\",\"open\")",
      created_at: 2.days.ago
    )

    get "/api/v1/admin/audit_logs/export", params: { sort_direction: "asc" }

    expect(response).to have_http_status(:ok)
    expect(response.body.index("users#updated")).to be < response.body.index("users#created")
    expect(response.body).to include("'=HYPERLINK")
    expect(response.body).not_to include(",=HYPERLINK")
  end
end
