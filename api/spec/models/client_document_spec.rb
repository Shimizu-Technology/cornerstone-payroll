# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClientDocument, type: :model do
  describe ".upload_validation_errors" do
    it "sniffs bytes even when the declared MIME matches the extension" do
      file = portal_upload("notice.pdf", "MZ\x00program", "application/pdf")
      expect(described_class.upload_validation_errors(file).join).to include("does not match")
    end

    it "rejects a valid PDF under another extension or declared content type" do
      expect(described_class.upload_validation_errors(portal_upload("notice.jpg", "%PDF-1.4\n", "image/jpeg"))).not_to be_empty
      expect(described_class.upload_validation_errors(portal_upload("notice.pdf", "%PDF-1.4\n", "image/png"))).not_to be_empty
    end

    it "accepts byte-identified PDF, UTF-8 TXT, CSV and matching Office containers" do
      [ portal_upload("notice.pdf", "%PDF-1.4\n"), portal_upload("notes.txt", "Payroll notes\n", "text/plain"),
        portal_upload("hours.csv", "name,hours\nAva,40\n", "application/vnd.ms-excel"),
        portal_upload("hours.xlsx", office_zip), portal_upload("notes.docx", office_zip(extension: "docx")) ].each do |file|
        expect(described_class.upload_validation_errors(file)).to be_empty, file.original_filename
      end
    end

    it "rejects macros even when renamed as macro-free Office files" do
      %w[xlsm docm exe zip].each do |extension|
        expect(described_class.upload_validation_errors(portal_upload("bad.#{extension}", office_zip))).not_to be_empty
      end
      expect(described_class.upload_validation_errors(portal_upload("bad.xlsx", office_zip(extra: { "xl/vbaProject.bin" => "synthetic" }))).join).to include("macros")
    end

    it "accepts a real legacy XLS and rejects renamed OLE macros and Excel 4 macro streams" do
      require "spreadsheet"
      workbook = Spreadsheet::Workbook.new
      workbook.create_worksheet.row(0).concat([ "Employee", "Hours" ])
      stream = StringIO.new
      workbook.write(stream)
      expect(described_class.upload_validation_errors(portal_upload("hours.xls", stream.string, "application/vnd.ms-excel"))).to be_empty
      malicious = StringIO.new
      Ole::Storage.open(malicious) do |ole|
        ole.file.open("Workbook", "w") { |file| file.write([ 0x0809, 4, 0x0600, 0x0040 ].pack("vvvv")) }
      end
      expect(described_class.upload_validation_errors(portal_upload("macro.xls", malicious.string)).join).to include("macros")
    end

    it "rejects malformed, mismatched and unsupported Office containers" do
      expect(described_class.upload_validation_errors(portal_upload("bad.xlsx", office_zip(extension: "docx")))).not_to be_empty
      expect(described_class.upload_validation_errors(portal_upload("bad.doc", office_zip))).not_to be_empty
      expect(described_class.upload_validation_errors(portal_upload("bad.xlsx", "PK\x03\x04broken"))).not_to be_empty
    end

    it "rejects empty, oversized and binary text files" do
      expect(described_class.upload_validation_errors(portal_upload("empty.txt", "")).join).to include("empty")
      file = portal_upload("large.txt", "small")
      allow(file).to receive(:size).and_return(described_class::MAX_FILE_SIZE + 1)
      expect(described_class.upload_validation_errors(file).join).to include("25 MB")
      expect(described_class.upload_validation_errors(portal_upload("bad.csv", "a,b\x00\n"))).not_to be_empty
    end

    it "bounds ZIP entry count and expanded bytes before conversion" do
      stub_const("ClientDocumentFileValidator::MAX_ZIP_ENTRIES", 3)
      file = portal_upload("many.xlsx", office_zip(extra: { "extra" => "harmless" }))
      expect(described_class.upload_validation_errors(file).join).to include("too many items")
      stub_const("ClientDocumentFileValidator::MAX_ZIP_ENTRIES", 1_000)
      stub_const("ClientDocumentFileValidator::MAX_EXPANDED_BYTES", 2_048)
      file = portal_upload("bomb.xlsx", office_zip(extra: { "xl/data.xml" => "x" * 4_096 }))
      expect(described_class.upload_validation_errors(file).join).to include("expands")
    end
  end

  it "uses safe disposition filenames" do
    doc = build(:client_document, file_name: "../../folder\\evil\r\n\u202E.txt")
    expect(doc.download_filename).to eq("evil.txt")
  end

  it "retains message references on archival and prevents direct hard deletion" do
    doc = create(:client_document)
    thread = create(:client_portal_thread, company: doc.company)
    message = create(:client_portal_message, company: doc.company, client_portal_thread: thread, client_document: doc)
    expect(doc.archive_or_destroy!(actor: doc.uploaded_by)).to eq(:archived)
    expect(message.reload.client_document).to eq(doc)
    expect { doc.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect do
      described_class.transaction(requires_new: true) { doc.delete }
    end.to raise_error(ActiveRecord::StatementInvalid, /Retained portal/)
    expect(ClientPortalThreadSerializer.new(current_user: doc.uploaded_by).message(message)[:document]).to include(title: doc.title, archived_at: doc.archived_at)
  end

  it "prevents company deletion from bypassing message retention before any cascade" do
    doc = create(:client_document)
    thread = create(:client_portal_thread, company: doc.company)
    message = create(:client_portal_message, company: doc.company, client_portal_thread: thread, client_document: doc)
    expect { doc.company.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(message.reload.client_document).to eq(doc)
    expect(doc.reload).to be_persisted
  end
end

RSpec.describe "Payroll export compatibility" do
  def errors(name, bytes, mime = "application/octet-stream")
    ClientDocument.upload_validation_errors(portal_upload(name, bytes, mime))
  end

  it "accepts Windows-1252 CSV with Chamorro names" do
    expect(errors("hours.csv", "Name,Hours\nPeña Åda,40\n".encode("Windows-1252"))).to be_empty
  end

  it "accepts BOM-marked UTF-16LE CSV from Excel Unicode Text" do
    expect(errors("hours.csv", "\xFF\xFE".b + "Name\tHours\nPeña,40\n".encode("UTF-16LE").b)).to be_empty
  end

  it "accepts Windows-1252 TXT" do
    expect(errors("notes.txt", "Peña Åda\n".encode("Windows-1252"))).to be_empty
  end

  it "accepts POS CSV with a stray quote" do
    expect(errors("sales.csv", "Item,Count\n12 inch 5\" pizza,2\n")).to be_empty
  end

  %w[application/csv text/x-csv].each do |mime|
    it("accepts CSV declared as #{mime}") { expect(errors("hours.csv", "Name,Hours\nPeña,40\n", mime)).to be_empty }
  end

  it "allows a DOCX with a native chart's embedded workbook" do
    expect(errors("chart.docx", office_zip(extension: "docx", extra: { "word/embeddings/Microsoft_Excel_Worksheet.xlsx" => office_zip }))).to be_empty
  end

  it "rejects embedded OLE, executable and unknown binaries" do
    %w[oleObject1.bin program.exe unknown.bin].each do |name|
      expect(errors("chart.docx", office_zip(extension: "docx", extra: { "word/embeddings/#{name}" => "binary" }))).not_to be_empty
    end
  end

  it "rejects a macro workbook inside an embedded OOXML package" do
    macro = office_zip(extra: { "xl/vbaProject.bin" => "macro" })
    expect(errors("chart.docx", office_zip(extension: "docx", extra: { "word/embeddings/chart.xlsx" => macro }))).not_to be_empty
  end

  it "bounds embedding recursion and aggregate expansion" do
    nested = office_zip
    5.times { nested = office_zip(extra: { "xl/embeddings/child.xlsx" => nested }) }
    expect(errors("nested.xlsx", nested)).not_to be_empty
    stub_const("ClientDocumentFileValidator::MAX_EXPANDED_BYTES", 8_000)
    inner = office_zip(extra: { "xl/data.xml" => "x" * 5_000 })
    outer = office_zip(extra: { "xl/embeddings/a.xlsx" => inner, "xl/embeddings/b.xlsx" => inner })
    expect(errors("nested.xlsx", outer).join).to include("expands")
  end

  it "allows small ZIP padding but rejects large padding or an appended program" do
    expect(errors("hours.xlsx", office_zip + "\x00" * 128)).to be_empty
    expect(errors("hours.xlsx", office_zip + "\x00" * 4_097)).not_to be_empty
    expect(errors("hours.xlsx", office_zip + "MZprogram")).not_to be_empty
  end

  it "explains HTML and text disguised as XLS" do
    [ "<html><table><tr><td>Hours</td></tr></table></html>", "Name\tHours\nPeña\t40\n" ].each do |bytes|
      expect(errors("export.xls", bytes).join).to include("This file is a web page or text file named .xls. Please export as .xlsx, .csv or PDF.")
    end
  end

  it "still rejects binary and control characters in every accepted encoding" do
    [ "a,b\x00\n".b, "Peña\u0001".encode("Windows-1252"), "Peña\u007f".encode("UTF-16LE").b.prepend("\xFF\xFE".b), "MZ\x00program".b ].each do |bytes|
      expect(errors("bad.csv", bytes)).not_to be_empty
    end
  end
end
