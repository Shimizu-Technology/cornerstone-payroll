# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Practice filing profile", type: :request do
  let(:company) { create(:company) }
  let(:user) { create(:user, company: company, role: "admin") }
  before do
    allow_any_instance_of(Api::V1::Admin::FilingSubmittersController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::FilingSubmittersController).to receive(:current_user).and_return(user)
  end

  it "returns an incomplete profile and saves identifiers without accepting passwords" do
    get "/api/v1/admin/filing_submitter"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("exists" => false, "can_edit" => true)
    expect(FilingSubmitter.where(organization: company.organization)).to be_empty
    expect(response.parsed_body["missing_fields"]).to include("bso_user_id")
    patch "/api/v1/admin/filing_submitter", params: { profile: { bso_user_id: "ABCDEFGH", password: "never-store-this" } }
    expect(response).to have_http_status(:ok)
    expect(FilingSubmitter.find_by!(organization: company.organization).bso_user_id).to eq("ABCDEFGH")
    patch "/api/v1/admin/filing_submitter", params: { profile: { bso_user_id: "IJKLMNOP" } }
    expect(response).to have_http_status(:ok)
    expect(FilingSubmitter.find_by!(organization: company.organization).bso_user_id).to eq("IJKLMNOP")
    expect(FilingSubmitter.column_names).not_to include("password")
  end

  it "blocks writes in a test workspace" do
    company.update_columns(payroll_environment: "migration_rehearsal", test_workspace_purpose: "sandbox", migration_source_company_id: create(:company).id, migration_rehearsal_status: "ready", test_workspace_expires_at: 1.day.from_now, migration_rehearsal_created_by_id: user.id)
    patch "/api/v1/admin/filing_submitter", params: { profile: { name: "Changed" } }
    expect(response).to have_http_status(:forbidden)
    expect(FilingSubmitter.where(organization: company.organization)).to be_empty
  end

  it "recovers when concurrent profile creation reaches the uniqueness validator" do
    profile = FilingSubmitter.create!(organization: company.organization)
    allow(FilingSubmitter).to receive(:find_by).and_return(nil, profile)
    allow(FilingSubmitter).to receive(:create_or_find_by!).and_raise(ActiveRecord::RecordInvalid.new(profile))
    patch "/api/v1/admin/filing_submitter", params: { profile: { name: "Updated practice" } }
    expect(response).to have_http_status(:ok)
    expect(profile.reload.name).to eq("Updated practice")
    expect(FilingSubmitter.where(organization: company.organization).count).to eq(1)
  end

  it "allows staff to read, but requires organization administration to edit" do
    profile = FilingSubmitter.create!(organization: company.organization, name: "Practice")
    user.update!(role: "accountant")
    get "/api/v1/admin/filing_submitter"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to include("exists" => true, "can_edit" => false)
    expect(response.parsed_body["profile"]["name"]).to eq("Practice")
    patch "/api/v1/admin/filing_submitter", params: { profile: { name: "Changed" } }
    expect(response).to have_http_status(:forbidden)
    expect(profile.reload.name).to eq("Practice")
  end
end
