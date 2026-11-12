# frozen_string_literal: true

require "rails_helper"

# The staff conversation list shares ClientPortalThreadActions with the client
# namespace, so it is capped at the same page size and pages the same way.
RSpec.describe "Staff portal conversation list paging", type: :request do
  let(:organization) { create(:organization) }
  let(:company) { create(:company, organization: organization) }
  let(:staff) { create(:user, company: company, organization: organization, role: "accountant", platform_owner: false) }
  let(:same_time) { Time.zone.parse("2026-11-01 09:00") }

  before do
    actor_id = staff.id
    allow_any_instance_of(Api::V1::Admin::PortalThreadsController).to receive(:current_user) { User.find(actor_id) }
    3.times { |index| create(:client_portal_thread, company: company, created_by: staff, subject: "Staff #{index}", last_message_at: same_time) }
  end

  it "returns paging metadata and walks every conversation once, newest id first on ties" do
    ids = [ 1, 2 ].flat_map do |page|
      get "/api/v1/admin/portal_threads", params: { per_page: 2, page: page }
      expect(response).to have_http_status(:ok), response.body
      expect(response.parsed_body.fetch("meta")).to include("total_count" => 3, "total_pages" => 2, "current_page" => page)
      response.parsed_body.fetch("data").map { |row| row.fetch("id") }
    end

    expect(ids).to eq(ClientPortalThread.where(company: company).order(id: :desc).pluck(:id))
  end

  it "uses the shared default page size" do
    get "/api/v1/admin/portal_threads"

    expect(response.parsed_body.dig("meta", "per_page")).to eq(BoundedListPagination::DEFAULT_LIST_PER_PAGE)
  end
end
