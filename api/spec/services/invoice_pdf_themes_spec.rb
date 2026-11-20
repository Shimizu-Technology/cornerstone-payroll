# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"
require "zlib"

RSpec.describe "Invoice PDF themes" do
  let(:invoice) do
    create(:invoice, invoice_number: "7055", invoice_date: Date.new(2026, 11, 2), due_date: Date.new(2026, 11, 17),
                     service_period_start: Date.new(2026, 11, 1), service_period_end: Date.new(2026, 11, 30),
                     payment_terms: "Net 15", notes: nil).tap do |record|
      record.line_items.create!(item_name: "Accounting Consulting", description: "Accounting Services – November 2026",
                                quantity: 1, rate: 3000, position: 0)
      record.line_items.create!(item_name: "Reimbursement", line_kind: "reimbursement", quantity: 1, rate: 1234.56,
                                description: "Social Security and Medicare paid on the client's behalf", position: 1)
      record.save!
    end
  end
  let(:profile) { invoice.invoice_billing_profile }

  before do
    profile.update!(name: "Marianas Bay CPA", legal_name: "Marianas Bay CPA", address: "PO Box 0000\nBarrigada, GU 96921",
                    payment_instructions: "Make checks payable to Marianas Bay CPA.",
                    footer_note: "Thank you so much for the opportunity to work with you!")
  end

  def render(snapshot, logo: InvoicePdfGenerator::NO_LOGO)
    InvoicePdfGenerator.new(nil, snapshot: snapshot, logo: logo).generate
  end

  def reader(bytes)
    PDF::Reader.new(StringIO.new(bytes))
  end

  # pdf-reader drops some word spaces in Source Sans 3 and Manrope, although
  # poppler and pdf.js extract them, so text is compared without whitespace.
  def text_of(bytes)
    compact(reader(bytes).pages.map(&:text).join)
  end

  def compact(text)
    text.gsub(/\s+/, "")
  end

  matcher :show do |*expected|
    match { |actual| expected.all? { |value| actual.include?(compact(value)) } }
    match_when_negated { |actual| expected.none? { |value| actual.include?(compact(value)) } }
    failure_message { |actual| "expected the PDF text to show #{(expected.reject { |value| actual.include?(compact(value)) }).inspect}" }
    failure_message_when_negated { |actual| "expected the PDF text not to show #{(expected.select { |value| actual.include?(compact(value)) }).inspect}" }
  end

  def snapshot_for(theme, **style)
    profile.update!(invoice_theme: theme, **style)
    invoice.reload.draft_snapshot
  end

  # A solid-color RGB PNG, so logo tests need no image library.
  def png(width, height)
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    rows = ([ "\x00".b + ("\xC2\x41\x0C".b * width) ] * height).join
    "\x89PNG\r\n\x1A\n".b + chunk.call("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("N2C5")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(rows)) + chunk.call("IEND", "")
  end

  describe "theme dispatch" do
    InvoicePdf::Style::THEMES.each do |theme|
      it "renders #{theme} with the invoice number, parties, lines and totals" do
        snapshot = snapshot_for(theme)
        generator = InvoicePdfGenerator.new(nil, snapshot: snapshot, logo: InvoicePdfGenerator::NO_LOGO)
        text = text_of(generator.generate)

        expect(generator.theme).to eq(theme)
        expect(generator.template_version).to eq("#{theme}-v1")
        expect(text).to show("7055", invoice.invoice_recipient.name, "Accounting Consulting", "Accounting Services",
                                "Reimbursement", "$3,000.00", "$1,234.56", "$4,234.56", "Marianas Bay CPA",
                                "Make checks payable to Marianas Bay CPA.", "Thank you so much")
        expect(text).not_to show("REMIT TO")
      end
    end

    it "uses the legacy layout for a snapshot recorded before themes" do
      generator = InvoicePdfGenerator.new(nil, snapshot: invoice.draft_snapshot.except("style"))
      text = text_of(generator.generate)

      expect(generator.theme).to eq("legacy")
      expect(generator.template_version).to eq("standard-v3")
      expect(generator.renderer_version).to eq("prawn-v2")
      expect(text).to show("BILL TO", "REMIT TO", "TOTAL DUE", "7055")
    end

    it "falls back to Classic for a style naming a theme this build does not know" do
      snapshot = invoice.draft_snapshot.merge("style" => { "theme" => "neon", "accent_color" => "#123456" })

      expect(InvoicePdfGenerator.new(nil, snapshot: snapshot).theme).to eq("classic")
    end

    it "still renders when a theme font cannot be loaded" do
      InvoicePdf::Fonts.reset!
      allow(TTFunk::File).to receive(:open).and_call_original
      allow(TTFunk::File).to receive(:open).with(%r{vendor/fonts/(inter|space-grotesk)/}).and_raise(Errno::ENOENT)

      expect(text_of(render(snapshot_for("modern")))).to show("7055", "$4,234.56")
      expect(InvoicePdf::Fonts.available?("Inter")).to be(false)
    ensure
      InvoicePdf::Fonts.reset!
    end
  end

  describe "draft marking" do
    it "prints Draft instead of the placeholder number and marks every page as a preview" do
      invoice.update!(invoice_number: "DRAFT-#{SecureRandom.uuid}")
      InvoicePdf::Style::THEMES.each do |theme|
        text = text_of(render(snapshot_for(theme)))

        expect(text).to show("Draft", "Draft preview")
        expect(text).not_to show("DRAFT-", "Issued")
      end
    end
  end

  describe "show and hide settings" do
    it "hides the product column, service period and how to pay when switched off" do
      InvoicePdf::Style::THEMES.each do |theme|
        text = text_of(render(snapshot_for(theme, show_item_column: false, show_service_period: false,
                                                   show_how_to_pay: false)))

        expect(text).not_to show("Accounting Consulting", "Make checks payable", "SERVICE PERIOD", "Service period",
                                 "HOW TO PAY", "Remittance")
        expect(text).to show("Accounting Services – November 2026", "Thank you so much")
      end
    end

    it "adds a service-date column only when a line has a date" do
      invoice.line_items.first.update!(service_date: Date.new(2026, 11, 3))
      InvoicePdf::Style::THEMES.each do |theme|
        expect(text_of(render(snapshot_for(theme)))).to show("11/03/2026")
      end
    end

    it "prints a percentage discount between the subtotal and total" do
      invoice.update!(discount_type: "percent", discount_value: 10)
      InvoicePdf::Style::THEMES.each do |theme|
        expect(text_of(render(snapshot_for(theme)))).to show("Discount (10.00%)", "-$423.46", "$3,811.10")
      end
    end
  end

  describe "logos" do
    it "places wide and square logos at every size in every theme" do
      InvoicePdf::Style::THEMES.each do |theme|
        InvoicePdf::Style::LOGO_SIZES.each do |size|
          [ png(600, 150), png(300, 300) ].each do |logo|
            pdf = reader(render(snapshot_for(theme, logo_size: size), logo: logo))

            expect(pdf.pages.first.xobjects.values.count { |object| object.hash[:Subtype] == :Image }).to eq(1)
            expect(pdf.pages.first.text).not_to include("MB\n")
          end
        end
      end
    end

    it "draws a monogram from the sender's initials when there is no logo" do
      InvoicePdf::Style::THEMES.each do |theme|
        expect(reader(render(snapshot_for(theme))).pages.first.text).to include("MB")
      end
    end
  end

  describe "pagination" do
    before do
      23.times do |index|
        invoice.line_items.create!(item_name: "Bookkeeping", quantity: 1, rate: 100 + index, position: index + 2,
                                   description: "Monthly bookkeeping and reconciliation for entity #{index + 1}, " \
                                                "with enough detail to wrap onto a second line in the table")
      end
      invoice.save!
    end

    InvoicePdf::Style::THEMES.each do |theme|
      it "repeats the table header, numbers pages and keeps the totals with the last lines in #{theme}" do
        pdf = reader(render(snapshot_for(theme)))
        pages = pdf.pages.map { |page| compact(page.text) }
        header = { "classic" => "DESCRIPTION", "modern" => "SERVICE", "professional" => "Description",
                   "banner" => "DESCRIPTION" }.fetch(theme)

        expect(pdf.page_count).to be > 1
        pages.each_with_index do |page, index|
          expect(page).to show(header, "Page #{index + 1} of #{pdf.page_count}")
        end
        expect(pages.drop(1)).to all(show("Invoice 7055", "continued"))
        expect(pages.last).to show("entity 23")
        expect(pages.last.scan("Bookkeeping").size).to be >= 2
        expect(pages.last).to match(/Total|Amountdue/)
        expect(pages.last).to show(invoice.reload.total_amount.to_fs(:currency))
        expect(pages[0...-1].join).not_to match(/Subtotal/)
      end
    end

    it "keeps body text clear of the page-number footer" do
      pdf = reader(render(snapshot_for("classic")))
      pdf.pages.each do |page|
        footer = page.runs.select { |run| run.text.start_with?("Page ") }
        body = page.runs.reject { |run| run.y < 45 }

        expect(footer).to be_present
        expect(body.map(&:y).min).to be > footer.map(&:y).max + 8
      end
    end
  end
end
