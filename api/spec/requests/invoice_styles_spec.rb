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

  it "saves the invoice number width and shows the next number with it" do
    patch "/api/v1/admin/invoice_billing_profiles/#{profile.id}", params: { invoice_billing_profile: {
      numbering_style: "continuing", next_invoice_number: 7055, invoice_number_width: 5
    } }, as: :json
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.fetch("invoice_billing_profile"))
      .to include("invoice_number_width" => 5, "next_invoice_number_preview" => "07055")

    patch "/api/v1/admin/invoice_billing_profiles/#{profile.id}", params: { invoice_billing_profile: { invoice_number_width: "" } }, as: :json
    expect(response.parsed_body.fetch("invoice_billing_profile")).to include("invoice_number_width" => nil, "next_invoice_number_preview" => "7055")
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

  describe "characters the PDF can't print" do
    def create_draft_for(name)
      recipient.update!(name: name)
      post "/api/v1/admin/invoices", params: { invoice: {
        invoice_billing_profile_id: profile.id, invoice_recipient_id: recipient.id, invoice_date: "2026-11-02",
        line_items: [ { item_name: "Consulting", description: "Fee\twith a tab", quantity: 1, rate: 100 } ]
      } }, as: :json
      expect(response).to have_http_status(:created), response.body
      Invoice.find(response.parsed_body.dig("invoice", "id"))
    end

    it "lists them on the draft so the editor can warn before issuing" do
      invoice = create_draft_for("東京 Trading 😀")

      get "/api/v1/admin/invoices/#{invoice.id}"

      expect(response.parsed_body.dig("invoice", "pdf_unprintable_text")).to eq([
        { "field" => "Customer name", "characters" => [ "東", "京", "😀" ] },
        { "field" => "Line 1 description", "characters" => [ "U+0009" ] }
      ])
      post "/api/v1/admin/invoices/#{invoice.id}/preview_pdf"
      expect(response).to have_http_status(:ok)
    end

    it "refuses every issue path with a message naming the field and characters" do
      profile.update!(numbering_style: "continuing", next_invoice_number: 7055)
      invoice = create_draft_for("東京 Trading")
      [
        -> { post "/api/v1/admin/invoices/#{invoice.id}/issue" },
        -> { post "/api/v1/admin/invoices/#{invoice.id}/generate_pdf" },
        -> { patch "/api/v1/admin/invoices/#{invoice.id}/update_status", params: { status: "open" } }
      ].each do |issue|
        expect { issue.call }.not_to change(InvoiceArtifact, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body.fetch("errors").join).to include("Customer name (東 京)", "Line 1 description (U+0009)",
                                                                       "empty boxes")
      end

      expect(invoice.reload).to have_attributes(status: "draft", snapshot: be_blank)
      expect(invoice.invoice_number).to start_with("DRAFT-")
      expect(profile.reload.next_invoice_number).to eq(7055)
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

    it "keeps the recorded style when an issued invoice is voided" do
      profile.update!(invoice_theme: "modern", accent_color: "#334155")
      invoice = issue_draft
      recorded = invoice.snapshot.fetch("style")
      sha = invoice.primary_artifact.sha256

      patch "/api/v1/admin/invoices/#{invoice.id}/update_status", params: { status: "voided", reason: "Billed twice" }
      expect(response).to have_http_status(:ok), response.body
      profile.update!(invoice_theme: "banner")

      expect(invoice.reload).to have_attributes(status: "voided")
      expect(invoice.snapshot.fetch("style")).to eq(recorded)
      expect(InvoicePdfGenerator.new(invoice).theme).to eq("modern")
      get "/api/v1/admin/invoices/#{invoice.id}/download_artifact"
      expect(Digest::SHA256.hexdigest(response.body)).to eq(sha)
    end

    it "records no style for an imported invoice, whose original file is the evidence" do
      profile.update!(invoice_theme: "banner")
      file = Tempfile.new([ "outside-invoice", ".pdf" ])
      file.binmode
      file.write("%PDF-1.4\nexternal invoice\n%%EOF\n")
      file.rewind
      post "/api/v1/admin/invoices/import", params: {
        file: Rack::Test::UploadedFile.new(file.path, "application/pdf", original_filename: "outside.pdf"),
        invoice_recipient_id: recipient.id, invoice_billing_profile_id: profile.id, invoice_number: "EXT-1",
        invoice_date: "2026-06-01", total_amount: "100.00"
      }

      expect(response).to have_http_status(:created), response.body
      invoice = Invoice.find(response.parsed_body.dig("invoice", "id"))
      expect(invoice.snapshot).not_to have_key("style")
      expect(invoice.primary_artifact).to have_attributes(kind: "imported_original", template_version: nil)
    ensure
      file&.close!
    end

    it "records the style and the allocated number on every continuing-number issue path" do
      profile.update!(numbering_style: "continuing", next_invoice_number: 7055, invoice_theme: "banner", logo_size: "large")
      paths = [
        ->(id) { post "/api/v1/admin/invoices/#{id}/issue" },
        ->(id) { post "/api/v1/admin/invoices/#{id}/generate_pdf" },
        ->(id) { patch "/api/v1/admin/invoices/#{id}/update_status", params: { status: "open" } }
      ]
      numbers = paths.map do |issue|
        post "/api/v1/admin/invoices", params: { invoice: {
          invoice_billing_profile_id: profile.id, invoice_recipient_id: recipient.id, invoice_date: "2026-11-02",
          line_items: [ { description: "Accounting Services – November 2026", quantity: 1, rate: 3000 } ]
        } }, as: :json
        invoice = Invoice.find(response.parsed_body.dig("invoice", "id"))
        issue.call(invoice.id)
        expect(response).to have_http_status(:ok), response.body
        invoice.reload
        expect(invoice.snapshot.fetch("style")).to eq(profile.invoice_style.to_snapshot)
        expect(invoice.snapshot.dig("invoice", "invoice_number")).to eq(invoice.invoice_number)
        expect(invoice.primary_artifact.template_version).to eq("banner-v1")
        invoice.invoice_number
      end

      expect(numbers).to eq(%w[7055 7056 7057])
    end

    it "gives a recurring draft no snapshot, so it previews in the profile's current style" do
      profile.update!(invoice_theme: "modern")
      source = issue_draft
      profile.update!(invoice_theme: "professional")
      recurrence = InvoiceRecurrence.create!(organization: source.organization, finance_book: source.finance_book,
                                             source_invoice: source, start_on: Date.new(2026, 12, 2),
                                             next_on: Date.new(2026, 12, 2), interval_unit: "month", interval_count: 1,
                                             due_after_days: 15)

      draft = InvoiceRecurrenceGenerator.generate!(recurrence.id, today: Date.new(2026, 12, 2))

      expect(draft).to have_attributes(status: "draft", snapshot: be_blank)
      expect(draft.draft_snapshot.dig("style", "theme")).to eq("professional")
      expect(source.reload.snapshot.dig("style", "theme")).to eq("modern")
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
