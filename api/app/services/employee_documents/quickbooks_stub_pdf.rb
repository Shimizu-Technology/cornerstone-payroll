# frozen_string_literal: true

module EmployeeDocuments
  class QuickbooksStubPdf
    class Invalid < StandardError; end

    # CombinePDF's parser can put raw PDF strings in warnings. Reject such
    # input here without sending the parser's diagnostic to application logs.
    class StrictParser < CombinePDF::PDFParser
      private

      def warn(*)
        raise Invalid, "Use the QuickBooks PDF, not a scan."
      end
    end

    MAX_BYTES = 10.megabytes
    MAX_PAGES = 50
    Page = Data.define(:number, :bytes, :text, :original_text, :issue, :has_image, :possible_ssn)

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
        original_page = original_pages.fetch(number - 1)
        original_text = scan_text(original_page)
        if issue_for(original_text)
          next unreadable_page(number)
        end

        if page[:Annots].present? || page[:AA].present?
          next unreadable_page(number)
        end

        page.except!(:Metadata, :PieceInfo, :Thumb)
        split = CombinePDF.new
        split.info[:CreationDate] = Time.utc(2026)
        split << page
        bytes = split.to_pdf
        archived_page = PDF::Reader.new(StringIO.new(bytes)).page(1)
        archived_text = scan_text(archived_page)
        next unreadable_page(number) if issue_for(archived_text)

        has_image = [ original_page, archived_page ].any? { |candidate| PdfImageReview.new(candidate).required? }
        possible_ssn = [ original_text, archived_text ].any? { |text| QuickbooksStubNumbers.possible_ssn?(text) }
        Page.new(number:, bytes:, text: archived_text, original_text:, issue: nil, has_image:, possible_ssn:)
      end
    rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError, PDF::Reader::InvalidPageError,
      CombinePDF::ParsingError, CombinePDF::EncryptionError, EncodingError
      raise Invalid, "Use the QuickBooks PDF, not a scan.", cause: nil
    end

    def self.scan_text(page)
      page.text.unicode_normalize(:nfkc)
    end
    private_class_method :scan_text

    def self.unreadable_page(number)
      Page.new(number:, bytes: nil, text: nil, original_text: nil, issue: "unreadable", has_image: false, possible_ssn: false)
    end

    def self.issue_for(text)
      text.blank? || text.include?("\uFFFD")
    end
    private_class_method :issue_for, :unreadable_page
  end
end
