# frozen_string_literal: true

require "stringio"

class StagingArtifactLabel
  def self.mark(bytes, filename:, type: "")
    return bytes unless StagingOutboundPolicy.staging?
    extension = File.extname(filename.to_s).downcase
    return pdf(bytes) if extension == ".pdf" || type.to_s.include?("pdf")
    return StagingOutboundPolicy::LABEL.b + "\n".b + bytes.b if extension == ".csv" || type.to_s.include?("csv")
    return zip(bytes) if extension == ".zip" || type.to_s.include?("zip")
    # Machine-submittable bank/filing formats and unmarkable archives are held.
    raise StagingOutboundPolicy::Blocked, "#{StagingOutboundPolicy::LABEL}: this export format is disabled in staging"
  end

  def self.pdf(bytes)
    require "combine_pdf"
    source = CombinePDF.parse(bytes)
    raise StagingOutboundPolicy::Blocked, "#{StagingOutboundPolicy::LABEL}: PDF cannot be marked" if source.pages.empty?
    source.pages.each do |page|
      dimensions = page[:CropBox] || page[:MediaBox] || [ 0, 0, 612, 792 ]
      overlay = Prawn::Document.new(page_size: [ dimensions[2] - dimensions[0], dimensions[3] - dimensions[1] ])
      page << CombinePDF.parse(overlay.render).pages.first
    end
    source.to_pdf
  rescue CombinePDF::ParsingError, CombinePDF::EncryptionError
    raise StagingOutboundPolicy::Blocked, "#{StagingOutboundPolicy::LABEL}: PDF cannot be marked"
  end

  def self.zip(bytes)
    require "zip"
    input = Zip::InputStream.new(StringIO.new(bytes))
    output = Zip::OutputStream.write_buffer do |archive|
      while (entry = input.get_next_entry)
        next if entry.directory?
        archive.put_next_entry("STAGING_#{entry.name}")
        archive.write(mark(input.read, filename: entry.name))
      end
      archive.put_next_entry("STAGING_DO_NOT_ISSUE_OR_FILE.txt")
      archive.write(StagingOutboundPolicy::LABEL)
    end
    output.string
  rescue Zip::Error
    raise StagingOutboundPolicy::Blocked, "#{StagingOutboundPolicy::LABEL}: archive cannot be marked"
  ensure
    input&.close
  end
end
