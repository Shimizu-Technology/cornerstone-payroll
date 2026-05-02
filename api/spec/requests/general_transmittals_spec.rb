# frozen_string_literal: true

require "rails_helper"

RSpec.describe "General Transmittals Admin API", type: :request do
  let!(:company) { create(:company, name: "Transmittal Client") }
  let!(:admin_user) { create(:user, company: company, role: "admin", email: "general-transmittals@example.com") }

  before do
    allow_any_instance_of(Api::V1::Admin::GeneralTransmittalsController).to receive(:current_user).and_return(admin_user)
    allow_any_instance_of(Api::V1::Admin::GeneralTransmittalsController).to receive(:current_company_id).and_return(company.id)
  end

  describe "POST /api/v1/admin/general_transmittals" do
    it "creates a draft with a manual item" do
      post "/api/v1/admin/general_transmittals",
        params: {
          general_transmittal: {
            title: "Quarterly packet",
            transmittal_date: "2026-05-02",
            notes: [ "Client pickup" ],
            items: [
              {
                item_type: "manual",
                title: "Quarterly return check",
                payable_to: "Guam DRT",
                check_number: "9001",
                amount: 100.25,
                details: [ "Q2 2026" ],
                position: 0
              }
            ]
          }
        }

      expect(response).to have_http_status(:created)
      body = response.parsed_body.fetch("general_transmittal")
      expect(body["title"]).to eq("Quarterly packet")
      expect(body["items"].first["title"]).to eq("Quarterly return check")
      expect(body["total_amount"]).to eq(100.25)
    end

    it "snapshots a standalone check" do
      check = create(:non_employee_check, :standalone, :with_check_number,
        company: company,
        payable_to: "Guam DRT",
        amount: 222.33,
        memo: "GRT payment")

      post "/api/v1/admin/general_transmittals",
        params: {
          general_transmittal: {
            title: "GRT packet",
            transmittal_date: "2026-05-02",
            items: [
              {
                source_type: "NonEmployeeCheck",
                source_id: check.id,
                position: 0
              }
            ]
          }
        }

      expect(response).to have_http_status(:created)
      item = response.parsed_body.dig("general_transmittal", "items").first
      expect(item["source_id"]).to eq(check.id)
      expect(item["payable_to"]).to eq("Guam DRT")
      expect(item["amount"]).to eq(222.33)
      expect(item["details"]).to include("For: GRT payment")
    end

    it "rejects duplicate linked checks in the same transmittal" do
      check = create(:non_employee_check, :standalone, company: company)

      post "/api/v1/admin/general_transmittals",
        params: {
          general_transmittal: {
            title: "Duplicate check packet",
            transmittal_date: "2026-05-02",
            items: [
              {
                source_type: "NonEmployeeCheck",
                source_id: check.id,
                position: 0
              },
              {
                source_type: "NonEmployeeCheck",
                source_id: check.id,
                position: 1
              }
            ]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"].join(" ")).to include("already been added to this transmittal")
    end
  end

  describe "PATCH /api/v1/admin/general_transmittals/:id" do
    it "rejects changing an existing item to a check from another company" do
      transmittal = create(:general_transmittal, :with_item, company: company)
      item = transmittal.items.first
      other_company = create(:company, name: "Other Client")
      other_check = create(:non_employee_check, :standalone, company: other_company)

      patch "/api/v1/admin/general_transmittals/#{transmittal.id}",
        params: {
          general_transmittal: {
            title: transmittal.title,
            transmittal_date: transmittal.transmittal_date.iso8601,
            items: [
              {
                id: item.id,
                source_type: "NonEmployeeCheck",
                source_id: other_check.id,
                position: 0
              }
            ]
          }
        }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Standalone check not found")
      expect(item.reload.source_type).to be_nil
      expect(item.source_id).to be_nil
    end
  end

  describe "DELETE /api/v1/admin/general_transmittals/:id" do
    it "deletes draft transmittals" do
      transmittal = create(:general_transmittal, company: company)

      delete "/api/v1/admin/general_transmittals/#{transmittal.id}"

      expect(response).to have_http_status(:ok)
      expect(GeneralTransmittal.exists?(transmittal.id)).to be(false)
    end

    it "does not delete generated transmittals" do
      transmittal = create(:general_transmittal, :with_item,
        company: company,
        status: "generated",
        generated_at: Time.current)

      delete "/api/v1/admin/general_transmittals/#{transmittal.id}"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to eq("Generated transmittals cannot be deleted")
      expect(GeneralTransmittal.exists?(transmittal.id)).to be(true)
    end
  end

  describe "POST /api/v1/admin/general_transmittals/:id/generate_pdf" do
    it "marks the transmittal generated and returns a PDF" do
      transmittal = create(:general_transmittal, :with_item, company: company)

      post "/api/v1/admin/general_transmittals/#{transmittal.id}/generate_pdf"

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/pdf")
      expect(response.body).to start_with("%PDF")
      expect(transmittal.reload.status).to eq("generated")
      expect(transmittal.generated_at).to be_present
    end

    it "leaves the transmittal as a draft when PDF generation fails" do
      transmittal = create(:general_transmittal, :with_item, company: company)
      allow_any_instance_of(GeneralTransmittalPdfGenerator)
        .to receive(:generate)
        .and_raise(StandardError, "PDF failure")

      expect do
        post "/api/v1/admin/general_transmittals/#{transmittal.id}/generate_pdf"
      end.to raise_error(StandardError, "PDF failure")

      expect(transmittal.reload.status).to eq("draft")
      expect(transmittal.generated_at).to be_nil
    end

    it "returns validation errors when the transmittal can no longer be marked generated" do
      transmittal = create(:general_transmittal, :with_item, company: company)
      transmittal.errors.add(:items, "must include at least one item")
      allow_any_instance_of(GeneralTransmittal)
        .to receive(:mark_generated!)
        .and_raise(ActiveRecord::RecordInvalid.new(transmittal))

      post "/api/v1/admin/general_transmittals/#{transmittal.id}/generate_pdf"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["errors"]).to include("Items must include at least one item")
      expect(transmittal.reload.status).to eq("draft")
    end
  end
end
