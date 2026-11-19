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
    expect(response.parsed_body["missing_fields"]).to include("bso_user_id")
    patch "/api/v1/admin/filing_submitter", params: { profile: { bso_user_id: "ABCDEFGH", password: "never-store-this" } }
    expect(response).to have_http_status(:ok)
    expect(FilingSubmitter.find_by!(organization: company.organization).bso_user_id).to eq("ABCDEFGH")
    expect(FilingSubmitter.column_names).not_to include("password")
  end

  it "allows staff to read, but requires organization administration to edit" do
    user.update!(role: "accountant")
    get "/api/v1/admin/filing_submitter"
    expect(response).to have_http_status(:ok)
    patch "/api/v1/admin/filing_submitter", params: { profile: { name: "Changed" } }
    expect(response).to have_http_status(:forbidden)
  end
end
