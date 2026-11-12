# frozen_string_literal: true

require "rails_helper"

RSpec.describe PdfUnicodeFont do
  let(:helvetica) { Prawn::Document.new }
  let(:pdf) { described_class.document }

  it "renders every supported script through text, tables, boxes and explicit Helvetica selection" do
    pdf.text UnicodePdfNames::TOKENS.first(3).join(" "), style: :bold
    pdf.formatted_text [ { text: "Łukasz ", styles: [ :italic ] }, { text: "Żółć ", styles: [ :bold, :italic ] }, { text: "Kāne Keʻala" } ]
    pdf.table([ [ "Ştefănescu", "Δημήτρης" ] ], cell_style: { font_style: :bold })
    pdf.text_box "Шевченко", at: [ 0, 100 ], width: 200
    pdf.font("Helvetica-Bold") { pdf.text "Mañibusan Hagåtña" }
    pdf.draw_text "Nguyễn Hương", at: [ 0, 40 ]

    text = unicode_pdf_text(pdf.render)
    expect(text).to include(*UnicodePdfNames::TOKENS, "Łukasz", "Keʻala", "Hagåtña")
  end

  it "maps the built-in Helvetica family names to the embedded font" do
    %w[Helvetica Helvetica-Bold Helvetica-Oblique Helvetica-BoldOblique].each do |family|
      pdf.font(family)
      expect(pdf.font).to be_a(PdfUnicodeFont::HelveticaMetricsTTF), family
    end
    pdf.font("Helvetica", style: :bold)
    expect(pdf.font.name).to end_with("LiberationSans-Bold.ttf")
  end

  it "keeps Helvetica's line heights and widths so existing layouts still fit" do
    { normal: "Helvetica", bold: "Helvetica-Bold" }.each do |style, builtin|
      helvetica.font(builtin)
      pdf.font(PdfUnicodeFont::FAMILY, style: style)
      expect(pdf.font.height_at(10)).to be_within(0.001).of(helvetica.font.height_at(10))
      expect(pdf.font.ascender).to eq(helvetica.font.ascender)
      expect(pdf.font.descender).to eq(helvetica.font.descender)

      sample = "Payroll Register 03/19/2026 Net Pay $1,216.35 SANTOS, JOHN"
      expect(pdf.width_of(sample, size: 9)).to be_within(0.5).of(helvetica.width_of(sample, size: 9))
    end
  end

  it "gives every font in a document a distinct resource name" do
    pdf.text "Wiśniewska"
    pdf.text "Nguyễn", style: :bold
    pdf.text "Mañibusan", style: :italic
    pdf.text "Żółć", style: :bold_italic

    expect(unicode_pdf_text(pdf.render)).to include("Wiśniewska", "Nguyễn", "Mañibusan", "Żółć")
  end

  it "builds the PDF instead of failing when a name has no glyph in the font" do
    pdf.text "王小明 김민수"
    expect(pdf.render).to start_with("%PDF")
  end

  it "lists only the characters the font has no glyph for" do
    expect(described_class.unprintable_characters("Wiśniewska Nguyễn Шевченко Keʻala")).to be_empty
    expect(described_class.unprintable_characters("王小明 Kim 王")).to eq(%w[王 小 明])
    expect(described_class.unprintable_characters(nil)).to be_empty
    expect(described_class.unprintable_characters("Taro\u3000Yamada")).to eq([ "\u3000" ])
    expect(described_class.unprintable_characters("12 Chalan\nHagåtña, GU\r\n")).to be_empty
    expect(described_class.unprintable_characters("Ana\tCruz")).to eq([ "\t" ])
  end

  it "names invisible characters by code point" do
    expect { described_class.ensure_printable!("Ana\uFEFFCruz", label: "Employee") }
      .to raise_error(PdfUnicodeFont::UnprintableName, /\(U\+FEFF\)/)
  end

  it "is used by every generator that draws text" do
    # The staging label overlay and the logo validator draw no text.
    allowed = %w[pdf_unicode_font.rb staging_artifact_label.rb invoice_logo_storage_service.rb]
    direct = Rails.root.glob("app/**/*.rb").select { |path| File.read(path).include?("Prawn::Document.new") }
    expect(direct.map { |path| path.basename.to_s }).to match_array(allowed)
  end
end

RSpec.describe "Staff PDF export failures", type: :request do
  let(:company) { create(:company) }
  let(:admin_user) { create(:user, company: company, role: "admin") }
  let(:pay_period) { create(:pay_period, :committed, company: company) }

  before do
    create(:payroll_item, pay_period: pay_period, employee: create(:employee, company: company), company: company)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_company_id).and_return(company.id)
    allow_any_instance_of(Api::V1::Admin::ReportsController).to receive(:current_user).and_return(admin_user)
  end

  it "returns the same clear JSON error on the staff register PDF" do
    allow_any_instance_of(PayrollRegisterPdfGenerator).to receive(:generate)
      .and_raise(Prawn::Errors::CannotFit)

    get "/api/v1/admin/reports/payroll_register_pdf", params: { pay_period_id: pay_period.id }

    expect(response).to have_http_status(:internal_server_error)
    expect(response.parsed_body.fetch("code")).to eq("pdf_generation_failed")
    expect(response.parsed_body.fetch("error")).to start_with("We couldn't create this PDF")
  end
end
