# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"
require "zlib"

RSpec.describe "Invoice style settings API", type: :request do
  let!(:company) { create(:company, name: "Shimizu Technology") }
  let!(:admin_user) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:recipient) { create(:invoice_recipient, organization: company.organization, company: nil, name: "Pacific Customer") }
  let!(:profile) do
    create(:invoice_billing_profile, organization: company.organization, name: "Marianas Bay CPA", is_default: true)
  end
  let(:current_user) { admin_user }

  before do
    [ Api::V1::Admin::InvoicesController, Api::V1::Admin::InvoiceBillingProfilesController ].each do |controller|
      allow_any_instance_of(controller).to receive(:current_user) { current_user }
      allow_any_instance_of(controller).to receive(:current_company_id).and_return(company.id)
    end
  end

  after do
    storage = R2StorageService.new
    InvoiceArtifact.where(organization_id: company.organization_id).pluck(:storage_key).each { |key| storage.delete(key) }
  end

  def pdf_text(body)
    PDF::Reader.new(StringIO.new(body)).pages.map(&:text).join.gsub(/\s+/, "")
  end

  def png_upload(width, height)
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    rows = ([ "\x00".b + ("\x1F\x4E\x79".b * width) ] * height).join
    bytes = "\x89PNG\r\n\x1A\n".b + chunk.call("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("N2C5")) +
            chunk.call("IDAT", Zlib::Deflate.deflate(rows)) + chunk.call("IEND", "")
    file = Tempfile.new([ "logo", ".png" ])
    file.binmode
    file.write(bytes)
    file.flush
    Rack::Test::UploadedFile.new(file.path, "image/png", original_filename: "logo.png")
  end

  def issue_draft
    post "/api/v1/admin/invoices", params: { invoice: {
      invoice_billing_profile_id: profile.id, invoice_recipient_id: recipient.id, invoice_date: "2026-11-02",
      line_items: [ { item_name: "Accounting Consulting", description: "Accounting Services – November 2026", quantity: 1, rate: 3000 } ]
    } }, as: :json
    expect(response).to have_http_status(:created), response.body
    invoice = Invoice.find(response.parsed_body.dig("invoice", "id"))
    post "/api/v1/admin/invoices/#{invoice.id}/issue"
    expect(response).to have_http_status(:ok), response.body
    invoice.reload
  end

  it "saves and returns the style settings" do
    patch "/api/v1/admin/invoice_billing_profiles/#{profile.id}", params: { invoice_billing_profile: {
      invoice_theme: "banner", accent_color: "#7c2d12", logo_size: "large", show_service_period: false,
      show_item_column: false, show_how_to_pay: false, footer_note: "Thank you!"
    } }, as: :json

    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("invoice_billing_profile")).to include(
      "invoice_theme" => "banner", "accent_color" => "#7C2D12", "effective_accent_color" => "#7C2D12",
      "logo_size" => "large", "show_service_period" => false, "show_item_column" => false,
      "show_how_to_pay" => false, "footer_note" => "Thank you!"
    )
    expect(profile.reload.invoice_theme).to eq("banner")
  end

  it "reports the theme color when no accent is chosen and rejects a bad accent or theme" do
    get "/api/v1/admin/invoice_billing_profiles/#{profile.id}"
    expect(response.parsed_body.dig("invoice_billing_profile", "effective_accent_color")).to eq("#1F4E79")

    patch "/api/v1/admin/invoice_billing_profiles/#{profile.id}",
          params: { invoice_billing_profile: { accent_color: "navy", invoice_theme: "neon" } }, as: :json

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body.fetch("errors")).to include("Accent color must be a hex color like #1F4E79",
                                                            "Invoice theme must be Classic, Modern, Professional or Banner")
    expect(profile.reload).to have_attributes(accent_color: nil, invoice_theme: "classic")
  end

  describe "sample PDF" do
    it "renders unsaved style choices without saving them" do
      post "/api/v1/admin/invoice_billing_profiles/#{profile.id}/sample_pdf",
           params: { invoice_billing_profile: { invoice_theme: "professional", footer_note: "Unsaved note" } }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/pdf")
      expect(response.headers["Content-Disposition"]).to start_with("inline")
      expect(pdf_text(response.body)).to include("Samplepreview,notaninvoice", "Unsavednote", "Preparedfor",
                                                 "SampleClientLLC", "$4,234.56")
      expect(profile.reload).to have_attributes(invoice_theme: "classic", footer_note: "Thank you for your business.")
    end

    it "previews a chosen logo, or the monogram while a removal is pending, without storing anything" do
      expect do
        post "/api/v1/admin/invoice_billing_profiles/#{profile.id}/sample_pdf",
             params: { invoice_billing_profile: { invoice_theme: "banner" }, logo: png_upload(400, 100) }
      end.not_to change { profile.reload.logo_storage_key }
      expect(response).to have_http_status(:ok), response.body
      images = PDF::Reader.new(StringIO.new(response.body)).pages.first.xobjects.values
      expect(images.count { |object| object.hash[:Subtype] == :Image }).to eq(1)

      post "/api/v1/admin/invoice_billing_profiles/#{profile.id}/sample_pdf", params: { remove_logo: "true" }
      expect(response).to have_http_status(:ok)
      expect(pdf_text(response.body)).to include("MB")
    end

    it "rejects an invalid preview accent or logo" do
      post "/api/v1/admin/invoice_billing_profiles/#{profile.id}/sample_pdf",
           params: { invoice_billing_profile: { accent_color: "#12" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("errors")).to eq([ "Accent color must be a hex color like #1F4E79" ])

      bad = Rack::Test::UploadedFile.new(StringIO.new("not an image"), "image/png", original_filename: "logo.png")
      post "/api/v1/admin/invoice_billing_profiles/#{profile.id}/sample_pdf", params: { logo: bad }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body.fetch("error")).to start_with("Logo")
    end

    it "downloads as an attachment when asked" do
      post "/api/v1/admin/invoice_billing_profiles/#{profile.id}/sample_pdf", params: { disposition: "attachment" }

      expect(response.headers["Content-Disposition"]).to include("attachment", "invoice-style-sample-classic.pdf")
    end

    it "keeps profiles from other organizations and other books out of reach" do
      other = create(:invoice_billing_profile, organization: create(:organization))
      post "/api/v1/admin/invoice_billing_profiles/#{other.id}/sample_pdf"
      expect(response).to have_http_status(:not_found)

      second_book = company.organization.finance_books.create!(name: "Client books", legal_name: "Client books",
                                                                kind: "organization")
      second_profile = InvoiceBillingProfile.create!(organization: company.organization, finance_book: second_book,
                                                     name: "Second book sender")
      first_book = company.organization.finance_books.find_by!(is_default: true)
      post "/api/v1/admin/invoice_billing_profiles/#{second_profile.id}/sample_pdf",
           headers: { "X-Finance-Book-Id" => first_book.id.to_s }
      expect(response).to have_http_status(:not_found)
    end

    context "as a manager" do
      let(:current_user) { create(:user, company: company, organization: company.organization, role: "manager") }

      it "is forbidden, like every other billing-profile action" do
        post "/api/v1/admin/invoice_billing_profiles/#{profile.id}/sample_pdf"
        expect(response).to have_http_status(:forbidden)

        patch "/api/v1/admin/invoice_billing_profiles/#{profile.id}",
              params: { invoice_billing_profile: { invoice_theme: "modern" } }, as: :json
        expect(response).to have_http_status(:forbidden)
        expect(profile.reload.invoice_theme).to eq("classic")
      end
    end
  end

  describe "issued invoices" do
    it "records the style in the snapshot and keeps the issued PDF when the profile changes" do
      profile.update!(invoice_theme: "modern", accent_color: "#334155", show_how_to_pay: false)
      invoice = issue_draft
      artifact = invoice.primary_artifact

      expect(invoice.snapshot_version).to eq(3)
      expect(invoice.snapshot.fetch("style")).to eq(
        "version" => 1, "theme" => "modern", "accent_color" => "#334155", "logo_size" => "medium",
        "show_service_period" => true, "show_item_column" => true, "show_how_to_pay" => false
      )
      expect(artifact).to have_attributes(template_version: "modern-v1", renderer_version: "prawn-themes-v1")

      profile.update!(invoice_theme: "banner", accent_color: nil)
      expect(InvoicePdfGenerator.new(invoice.reload).theme).to eq("modern")

      get "/api/v1/admin/invoices/#{invoice.id}/download_artifact"
      expect(Digest::SHA256.hexdigest(response.body)).to eq(artifact.sha256)
    end

    it "re-renders an invoice issued before themes with the legacy layout" do
      invoice = issue_draft
      invoice.update_column(:snapshot, invoice.snapshot.except("style"))
      profile.update!(invoice_theme: "banner")

      generator = InvoicePdfGenerator.new(invoice.reload)
      expect(generator.theme).to eq("legacy")
      expect(pdf_text(generator.generate)).to include("BILLTO", "REMITTO", "TOTALDUE")
    end

    it "previews drafts in the profile's current style" do
      post "/api/v1/admin/invoices", params: { invoice: {
        invoice_billing_profile_id: profile.id, invoice_recipient_id: recipient.id, invoice_date: "2026-11-02",
        line_items: [ { description: "Accounting Services – November 2026", quantity: 1, rate: 3000 } ]
      } }, as: :json
      invoice_id = response.parsed_body.dig("invoice", "id")
      profile.update!(invoice_theme: "professional")

      post "/api/v1/admin/invoices/#{invoice_id}/preview_pdf"

      expect(response).to have_http_status(:ok)
      expect(pdf_text(response.body)).to include("Preparedfor", "Draftpreview")
    end
  end
end
