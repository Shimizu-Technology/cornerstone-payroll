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

      [ "", "0", "-1", "abc" ].each do |value|
        it "falls back to the default page size when per_page is #{value.inspect}" do
          get path, headers: headers, params: { per_page: value }

          expect(response.parsed_body.fetch("data").size).to eq(3)
          expect(response.parsed_body.dig("meta", "per_page")).to eq(BoundedListPagination::DEFAULT_LIST_PER_PAGE)
        end
      end
    end
  end

  describe "rows that share a timestamp" do
    let(:same_time) { Time.zone.parse("2026-11-01 09:00") }

    def ids_across_pages(path)
      [ 1, 2, 3 ].flat_map do |page|
        get path, headers: headers, params: { per_page: 2, page: page }
        response.parsed_body.fetch("data").map { |row| row.fetch("id") }
      end
    end

    it "pages documents newest first by id without repeating or skipping any" do
      ClientDocument.update_all(created_at: same_time)
      ids = ids_across_pages("/api/v1/client/documents")

      expect(ids).to eq(ClientDocument.where(company: company).order(id: :desc).pluck(:id))
    end

    it "pages conversations newest first by id without repeating or skipping any" do
      ClientPortalThread.update_all(last_message_at: same_time)
      ids = ids_across_pages("/api/v1/client/portal_threads")

      expect(ids).to eq(ClientPortalThread.where(company: company).order(id: :desc).pluck(:id))
    end

    it "pages change requests newest first by id without repeating or skipping any" do
      EmployeeChangeRequest.update_all(created_at: same_time)
      ids = ids_across_pages("/api/v1/client/employee_change_requests")

      expect(ids).to eq(EmployeeChangeRequest.where(company: company).order(id: :desc).pluck(:id))
    end
  end

  describe "documents beyond the default page" do
    before do
      employee = create(:employee, company: company)
      now = Time.current
      rows = Array.new(BoundedListPagination::DEFAULT_LIST_PER_PAGE - 1) do |index|
        { company_id: company.id, uploaded_by_id: client_user.id, employee_id: employee.id, title: "Onboarding #{index}",
          category: "employee_onboarding", file_name: "w4-#{index}.pdf", file_key: "test/w4-#{index}.pdf",
          content_type: "application/pdf", file_size: 1024, visible_to_client: true, created_at: now, updated_at: now }
      end
      ClientDocument.insert_all!(rows)
    end

    it "caps the first page, reports the full totals, and returns the rest on the next page" do
      get "/api/v1/client/documents", headers: headers
      first_ids = response.parsed_body.fetch("data").map { |row| row.fetch("id") }
      expect(first_ids.size).to eq(BoundedListPagination::DEFAULT_LIST_PER_PAGE)
      expect(response.parsed_body.fetch("meta")).to include(
        "total_count" => 202, "total_pages" => 2, "current_page" => 1,
        "employee_linked_count" => BoundedListPagination::DEFAULT_LIST_PER_PAGE - 1
      )

      get "/api/v1/client/documents", headers: headers, params: { page: 2 }
      second_ids = response.parsed_body.fetch("data").map { |row| row.fetch("id") }
      expect(second_ids.size).to eq(2)
      expect(first_ids & second_ids).to be_empty
      expect(response.parsed_body.dig("meta", "employee_linked_count")).to eq(BoundedListPagination::DEFAULT_LIST_PER_PAGE - 1)
    end
  end
end
