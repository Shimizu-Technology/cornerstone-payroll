# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Client::PortalThreads", type: :request do
  let(:company) { create(:company) }
  let(:client_user) { create(:user, company: company, role: "client") }
  let(:staff_user) { create(:user, company: company, role: "accountant") }

  before do
    allow_any_instance_of(Api::V1::Client::PortalThreadsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Client::PortalThreadsController).to receive(:current_user).and_return(client_user)
    allow(ClientPortalThreadChannel).to receive(:broadcast_thread)
  end

  it "does not let client users resolve or reopen threads through a direct API call" do
    thread = create(:client_portal_thread, company: company, created_by: client_user, status: "open")

    patch "/api/v1/client/portal_threads/#{thread.id}", params: { status: "resolved" }

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body.fetch("error")).to eq("Not authorized to change thread status")
    expect(thread.reload.status).to eq("open")
  end

  it "allows staff callers in the client namespace to update thread status" do
    allow_any_instance_of(Api::V1::Client::PortalThreadsController).to receive(:current_user).and_return(staff_user)
    thread = create(:client_portal_thread, company: company, created_by: client_user, status: "open")

    patch "/api/v1/client/portal_threads/#{thread.id}", params: { status: "resolved" }

    expect(response).to have_http_status(:ok)
    expect(thread.reload).to be_resolved
    expect(thread.resolved_by).to eq(staff_user)
  end

  it "returns the committed last message timestamp when creating a thread with an initial message" do
    post "/api/v1/client/portal_threads", params: { subject: "Payroll notes", body: "Updated hours attached." }

    expect(response).to have_http_status(:created)

    data = response.parsed_body.fetch("data")
    expect(data.fetch("last_message_at")).to be_present
    expect(data.dig("latest_message", "body")).to eq("Updated hours attached.")

    created_thread = ClientPortalThread.find(data.fetch("id"))
    expect(created_thread.last_message_at).to be_present
    expect(Time.zone.parse(data.fetch("last_message_at")).to_i).to eq(created_thread.last_message_at.to_i)
    expect(ClientPortalThreadChannel).to have_received(:broadcast_thread).with(created_thread, event: "thread_created")
  end
end
