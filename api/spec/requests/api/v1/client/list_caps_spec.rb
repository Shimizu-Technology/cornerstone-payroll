# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Client portal list caps", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:client_user) { create(:user, company: company, organization: organization, role: "client", platform_owner: false) }
  let(:headers) { { "X-Company-Id" => company.id.to_s } }

  before do
    CompanyAssignment.create!(user: client_user, company: company)
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(client_user)
    allow_any_instance_of(ApplicationController).to receive(:current_user_id).and_return(client_user.id)

    3.times do |index|
      create(:client_document, company: company, uploaded_by: client_user, title: "Doc #{index}")
      create(:client_portal_thread, company: company, created_by: client_user, subject: "Thread #{index}",
        last_message_at: index.minutes.ago)
      create(:employee_change_request, company: company, employee: create(:employee, company: company),
        requested_by: client_user, status: :approved)
    end
  end

  {
    "documents" => "/api/v1/client/documents",
    "conversations" => "/api/v1/client/portal_threads",
    "change requests" => "/api/v1/client/employee_change_requests"
  }.each do |label, path|
    describe label do
      it "returns a bounded default page with paging metadata" do
        get path, headers: headers

        expect(response).to have_http_status(:ok), response.body
        expect(response.parsed_body.fetch("data").size).to eq(3)
        expect(response.parsed_body.fetch("meta")).to include(
          "total_count" => 3, "per_page" => BoundedListPagination::DEFAULT_LIST_PER_PAGE
        )
      end

      it "honors smaller pages and clamps oversized requests" do
        get path, headers: headers, params: { per_page: 2, page: 2 }
        expect(response.parsed_body.fetch("data").size).to eq(1)
        expect(response.parsed_body.dig("meta", "total_pages")).to eq(2)

        get path, headers: headers, params: { per_page: 50_000 }
        expect(response.parsed_body.dig("meta", "per_page")).to eq(BoundedListPagination::MAX_LIST_PER_PAGE)
      end
    end
  end
end
