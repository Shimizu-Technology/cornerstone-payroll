# frozen_string_literal: true

module EmployeeDocuments
  class QuickbooksStubPdf
    class Invalid < StandardError; end

    # CombinePDF's parser can put raw PDF strings in warnings. Reject such
    # input here without sending the parser's diagnostic to application logs.
    class StrictParser < CombinePDF::PDFParser
      private

      def warn(*)
        raise Invalid, "The PDF could not be read. Use a text-based QuickBooks export."
      end
    end

    MAX_BYTES = 10.megabytes
    MAX_PAGES = 50
    SSN = /(?<![0-9])[0-9]{3}[\p{Space}\p{Pd}.]*[0-9]{2}[\p{Space}\p{Pd}.]*[0-9]{4}(?![0-9])/
    Page = Data.define(:number, :bytes, :text, :issue)

    def self.read(file)
      raise Invalid, "Choose a PDF up to 10 MB." unless file.respond_to?(:read) && file.respond_to?(:size) &&
        file.size.between?(1, MAX_BYTES)

      content = file.read(MAX_BYTES + 1)
      raise Invalid, "Choose a PDF up to 10 MB." unless content&.start_with?("%PDF-") && content.bytesize <= MAX_BYTES

      reader = PDF::Reader.new(StringIO.new(content))
      raise Invalid, "Choose a PDF with 1 to 50 pages." unless reader.page_count.between?(1, MAX_PAGES)

      # Split before archival so each employee gets only the selected page.
      # Scan both the original page and the exact bytes that would be stored.
      original_pages = reader.pages
      pages = CombinePDF::PDF.new(StrictParser.new(content, raise_on_encrypted: true)).pages
      raise Invalid, "The PDF page inventory could not be verified." unless pages.size == original_pages.size

      pages.map.with_index(1) do |page, number|
        original_text = scan_text(original_pages.fetch(number - 1))
        if (issue = issue_for(original_text))
          next Page.new(number:, bytes: nil, text: nil, issue:)
        end

        if page[:Annots].present? || page[:AA].present?
          next Page.new(number:, bytes: nil, text: nil, issue: "unreadable")
        end

        page.except!(:Metadata, :PieceInfo, :Thumb)
        split = CombinePDF.new
        split.info[:CreationDate] = Time.utc(2026)
        split << page
        bytes = split.to_pdf
        archived_text = scan_text(PDF::Reader.new(StringIO.new(bytes)).page(1))
        issue = issue_for(archived_text)
        Page.new(number:, bytes: issue ? nil : bytes, text: issue ? nil : archived_text, issue:)
      end
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::InvalidPageError,
      CombinePDF::ParsingError, CombinePDF::EncryptionError, EncodingError
      raise Invalid, "The PDF could not be read. Use a text-based QuickBooks export.", cause: nil
    end

    def self.scan_text(page)
      page.text.unicode_normalize(:nfkc)
    end
    private_class_method :scan_text

    def self.issue_for(text)
      return "full_ssn" if SSN.match?(text)
      return "unreadable" if text.blank? || text.include?("\uFFFD")

      nil
    end
    private_class_method :issue_for
  end
end
