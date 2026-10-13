# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Portal request company scope", type: :request do
  let(:organization) { create(:organization) }
  let(:home) { create(:company, organization: organization) }
  let(:inaccessible) { create(:company, organization: organization) }
  let(:role) { "accountant" }
  let(:user) { create(:user, company: home, organization: organization, role: role, platform_owner: false) }
  let(:thread) do
    ClientPortalThread.create!(company: home, created_by: user, subject: "Original home conversation",
      last_message_at: 1.minute.ago)
  end

  before do
    actor_id = user.id
    [ Api::V1::Admin::PortalThreadsController, Api::V1::Admin::PortalMessagesController,
      Api::V1::Client::PortalThreadsController, Api::V1::Client::PortalMessagesController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user) { User.find(actor_id) }
    end
  end

  %w[admin client].each do |surface|
    describe "#{surface} routes" do
      let(:role) { surface == "client" ? "client" : "accountant" }
      let(:base) { "/api/v1/#{surface}/portal_threads" }

      %w[inaccessible malformed empty whitespace].each do |scope|
        context "with #{scope} company scope" do
          let(:headers) do
            value = case scope
            when "inaccessible" then inaccessible.id.to_s
            when "malformed" then "#{home.id}invalid"
            when "empty" then ""
            when "whitespace" then " "
            end
            { "X-Company-Id" => value }
          end

          it "denies show before marking the home conversation read" do
            sender = create(:user, company: home, organization: organization,
              role: surface == "client" ? "accountant" : "client", platform_owner: false)
            ClientPortalMessage.create!(company: home, client_portal_thread: thread,
              author: sender, body: "Unread incoming message")
            thread.reload
            expect(thread.unread_for?(user)).to be(true)
            original = thread.attributes
            get "#{base}/#{thread.id}", headers: headers
            expect(response).to have_http_status(:forbidden)
            expect(thread.reload.attributes).to eq(original)
            expect(thread.unread_for?(user)).to be(true)
          end

          it "denies update without changing the home conversation" do
            original = thread.attributes
            patch "#{base}/#{thread.id}", headers: headers, params: { subject: "Wrong client" }
            expect(response).to have_http_status(:forbidden)
            expect(thread.reload.attributes).to eq(original)
          end

          it "denies mark_read without changing the home conversation" do
            original = thread.attributes
            post "#{base}/#{thread.id}/mark_read", headers: headers
            expect(response).to have_http_status(:forbidden)
            expect(thread.reload.attributes).to eq(original)
          end

          it "denies conversation creation without saving a thread or message" do
            expect do
              post base, headers: headers, params: { subject: "Wrong client", body: "Must not be saved" }
            end.not_to change { [ ClientPortalThread.count, ClientPortalMessage.count ] }
            expect(response).to have_http_status(:forbidden)
          end

          it "denies a nested message without touching the home conversation" do
            original = thread.attributes
            expect do
              post "#{base}/#{thread.id}/messages", headers: headers, params: { body: "Must not be saved" }
            end.not_to change(ClientPortalMessage, :count)
            expect(response).to have_http_status(:forbidden)
            expect(thread.reload.attributes).to eq(original)
          end
        end
      end

      it "preserves no-header home-company reads" do
        get "#{base}/#{thread.id}"
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", "id")).to eq(thread.id)
        expect(thread.reload.unread_for?(user)).to be(false)
      end

      it "allows an explicit accessible home-company read" do
        get "#{base}/#{thread.id}", headers: { "X-Company-Id" => home.id.to_s }
        expect(response).to have_http_status(:ok)
        expect(response.parsed_body.dig("data", "id")).to eq(thread.id)
        expect(thread.reload.unread_for?(user)).to be(false)
      end

      it "allows an explicit accessible home-company message" do
        thread
        expect do
          post "#{base}/#{thread.id}/messages", headers: { "X-Company-Id" => home.id.to_s },
            params: { body: "Authorized explicit home message" }
        end.to change(ClientPortalMessage, :count).by(1)
        expect(response).to have_http_status(:created)
        expect(ClientPortalMessage.last.company_id).to eq(home.id)
        expect(ClientPortalMessage.last.author_id).to eq(user.id)
      end

      it "preserves no-header home-company message creation" do
        thread
        expect do
          post "#{base}/#{thread.id}/messages", params: { body: "Authorized home message" }
        end.to change(ClientPortalMessage, :count).by(1)
        expect(response).to have_http_status(:created)
        expect(ClientPortalMessage.last.company_id).to eq(home.id)
        expect(ClientPortalMessage.last.author_id).to eq(user.id)
      end
    end
  end
end
