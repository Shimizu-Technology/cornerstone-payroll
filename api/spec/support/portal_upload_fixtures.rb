# frozen_string_literal: true

module PortalUploadFixtures
  def portal_upload(name, bytes, mime = "application/octet-stream")
    file = Tempfile.new([ "portal-safety", File.extname(name) ])
    file.binmode
    file.write(bytes)
    file.rewind
    @portal_tempfiles ||= []
    @portal_tempfiles << file
    Rack::Test::UploadedFile.new(file.path, mime, original_filename: name)
  end

  def office_zip(extension: "xlsx", extra: {})
    main = extension == "docx" ? "word/document.xml" : "xl/workbook.xml"
    type = extension == "docx" ? "wordprocessingml.document" : "spreadsheetml.sheet"
    entries = {
      "[Content_Types].xml" => %(<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/#{main}" ContentType="application/vnd.openxmlformats-officedocument.#{type}.main+xml"/></Types>),
      "_rels/.rels" => "<Relationships/>",
      main => extension == "docx" ? '<document xmlns="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>' : '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"/>'
    }.merge(extra)
    Zip::OutputStream.write_buffer do |zip|
      entries.each do |name, bytes|
        zip.put_next_entry(name)
        zip.write(bytes)
      end
    end.string
  end
end

RSpec.configure do |config|
  config.include PortalUploadFixtures
  config.after do
    @portal_tempfiles&.each(&:close!)
  end
end
