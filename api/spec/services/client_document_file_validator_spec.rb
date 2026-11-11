# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientDocumentFileValidator do
  def errors(bytes, extension: "xlsx")
    ClientDocument.upload_validation_errors(portal_upload("synthetic.#{extension}", bytes)).join
  end

  it "rejects program extensions anywhere in Office packages" do
    %w[exe DLL com scr msi bat cmd ps1 sh py rb js jar].each do |extension|
      expect(errors(office_zip(extra: { "xl/payload.#{extension}" => "synthetic" }))).to include("programs"), extension
    end
  end

  it "rejects executable signatures under neutral names in XLSX and DOCX" do
    signatures = [ "MZprogram", "\x7FELFprogram", "#!/bin/sh\necho synthetic", "\xFE\xED\xFA\xCE", "\xCE\xFA\xED\xFE",
      "\xFE\xED\xFA\xCF", "\xCF\xFA\xED\xFE", "\xCA\xFE\xBA\xBE", "\xBE\xBA\xFE\xCA", "\xCA\xFE\xBA\xBF", "\xBF\xBA\xFE\xCA" ]
    signatures.each do |signature|
      %w[xlsx docx].each do |extension|
        expect(errors(office_zip(extension: extension, extra: { "custom/payload.dat" => signature.b }), extension: extension)).to include("programs"), signature.inspect
      end
    end
  end

  def relationship(type, mode: "External", target: "http://127.0.0.1/private")
    %(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/#{type}" Target="#{target}" TargetMode="#{mode}"/></Relationships>)
  end

  it "rejects external resources, including in embedded packages" do
    %w[image oleObject externalLink attachedTemplate].each do |type|
      workbook = office_zip(extra: { "xl/_rels/workbook.xml.rels" => relationship(type) })
      expect(errors(workbook)).to include("external resources")
      expect(errors(office_zip(extension: "docx", extra: { "word/embeddings/chart.xlsx" => workbook }), extension: "docx")).to include("external resources")
    end
  end

  it "accepts ordinary hyperlinks and internal images" do
    expect(errors(office_zip(extension: "docx", extra: { "word/_rels/document.xml.rels" => relationship("hyperlink") }), extension: "docx")).to be_empty
    expect(errors(office_zip(extra: { "xl/_rels/workbook.xml.rels" => relationship("image", mode: "Internal", target: "media/image1.png") }))).to be_empty
  end
end
