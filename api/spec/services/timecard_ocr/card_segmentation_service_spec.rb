# frozen_string_literal: true

require "rails_helper"

RSpec.describe TimecardOcr::CardSegmentationService do
  describe "#pdf_page_count" do
    it "counts every page in a multi-page PDF" do
      pdf = Prawn::Document.new(page_size: "LETTER") do |doc|
        doc.text "Page 1"
        doc.start_new_page
        doc.text "Page 2"
        doc.start_new_page
        doc.text "Page 3"
      end

      file = Tempfile.new(["timecards", ".pdf"])
      file.binmode
      file.write(pdf.render)
      file.close

      service = described_class.new(file.path)

      expect(service.send(:pdf_page_count)).to eq(3)
    ensure
      file&.unlink
    end
  end
end
