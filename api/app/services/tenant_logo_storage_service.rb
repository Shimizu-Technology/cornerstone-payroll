# frozen_string_literal: true

require "digest"
require "nokogiri"

# A client's employee-app logo: PNG, WebP or SVG, checked, cleaned and stored
# in R2. The logo is public (the sign-in screen shows it), so the bytes are
# cleaned before storage:
# - PNG keeps only image chunks; text, EXIF and timestamp chunks are dropped.
# - WebP drops its EXIF and XMP chunks.
# - SVG is parsed strictly and refused if it has scripts, event handlers,
#   external references or embedded documents. Comments, metadata and editor
#   attributes are removed.
class TenantLogoStorageService
  class InvalidLogo < StandardError; end

  MAX_BYTES = 1.megabyte
  MAX_EDGE = 2_400
  MAX_PIXELS = 4_000_000
  MIN_EDGE = 32

  PNG_SIGNATURE = "\x89PNG\r\n\x1A\n".b
  # Critical chunks plus the ancillary chunks that change how the image looks.
  PNG_KEEP_CHUNKS = %w[IHDR PLTE IDAT IEND tRNS gAMA cHRM sRGB iCCP sBIT].freeze
  WEBP_DROP_CHUNKS = [ "EXIF", "XMP " ].freeze
  WEBP_EXIF_FLAG = 0x08
  WEBP_XMP_FLAG = 0x04

  SVG_NAMESPACE = "http://www.w3.org/2000/svg"
  XLINK_NAMESPACE = "http://www.w3.org/1999/xlink"
  SVG_FORBIDDEN_ELEMENTS = %w[script foreignobject iframe embed object audio video canvas handler listener set animate animatemotion animatetransform image feimage a].freeze
  SVG_DROPPED_ELEMENTS = %w[metadata title desc].freeze
  SVG_CONTENT_ERROR = "SVG logos can't include scripts, links, embedded images or other documents. Export a plain SVG or use PNG"
  SVG_KEPT_NAMESPACES = [ SVG_NAMESPACE, XLINK_NAMESPACE, "http://www.w3.org/XML/1998/namespace" ].freeze

  def initialize(storage: R2StorageService.new)
    @storage = storage
  end

  # Cleans and stores the file under a content-addressed key. Returns the
  # attributes to save on the company. The caller saves them with its audit
  # row, then deletes the replaced object (or this one, if the save fails).
  def store!(company:, file:)
    bytes, content_type = clean(file)
    sha = Digest::SHA256.hexdigest(bytes)
    key = StagingStoragePolicy.new_key("tenant-brand/company-#{company.id}/#{sha}.#{Company::BRAND_LOGO_EXTENSIONS.fetch(content_type)}")
    @storage.upload(key, StringIO.new(bytes), content_type: content_type)
    { brand_logo_storage_key: key, brand_logo_content_type: content_type,
      brand_logo_sha256: sha, brand_logo_byte_size: bytes.bytesize }
  end

  def download(company)
    key = company.brand_logo_storage_key.presence
    return unless key

    bytes = @storage.download_with_limit(key, max_bytes: MAX_BYTES)
    return unless bytes && Digest::SHA256.hexdigest(bytes) == company.brand_logo_sha256

    bytes
  end

  def delete_object(key)
    @storage.delete(key) if key.present?
  rescue StandardError => e
    Rails.logger.warn("Tenant logo delete failed: #{e.class}")
  end

  # Returns [clean_bytes, content_type] or raises InvalidLogo with a message
  # the person uploading can act on.
  def clean(file)
    raise InvalidLogo, "Choose a PNG, SVG or WebP logo" unless file.respond_to?(:read)
    raise InvalidLogo, "The logo must be 1 MB or smaller" if file.respond_to?(:size) && file.size.to_i > MAX_BYTES

    bytes = file.read(MAX_BYTES + 1).to_s.b
    file.rewind if file.respond_to?(:rewind)
    raise InvalidLogo, "The logo must be 1 MB or smaller" if bytes.bytesize > MAX_BYTES
    raise InvalidLogo, "That file is empty" if bytes.empty?

    if bytes.start_with?(PNG_SIGNATURE)
      [ clean_png(bytes), "image/png" ]
    elsif bytes.byteslice(0, 4) == "RIFF" && bytes.byteslice(8, 4) == "WEBP"
      [ clean_webp(bytes), "image/webp" ]
    elsif svg_candidate?(bytes)
      [ clean_svg(bytes), "image/svg+xml" ]
    else
      raise InvalidLogo, "The logo must be a PNG, SVG or WebP image"
    end
  end

  private

  def check_dimensions!(width, height)
    unless width.to_i.positive? && height.to_i.positive?
      raise InvalidLogo, "That image couldn't be read. Try exporting it again as PNG"
    end
    if width > MAX_EDGE || height > MAX_EDGE || width * height > MAX_PIXELS
      raise InvalidLogo, "The logo must be at most #{MAX_EDGE} pixels on each side"
    end
    return unless width < MIN_EDGE || height < MIN_EDGE

    raise InvalidLogo, "The logo is too small. Use one at least #{MIN_EDGE} pixels on each side"
  end

  def clean_png(bytes)
    offset = PNG_SIGNATURE.bytesize
    kept = [ PNG_SIGNATURE ]
    seen_end = false
    first = true
    while offset + 12 <= bytes.bytesize
      length = bytes.byteslice(offset, 4).unpack1("N")
      type = bytes.byteslice(offset + 4, 4)
      chunk_end = offset + 12 + length
      raise InvalidLogo, "That PNG file is damaged" if length > MAX_BYTES || chunk_end > bytes.bytesize
      raise InvalidLogo, "That PNG file is damaged" if first && type != "IHDR"

      chunk = bytes.byteslice(offset, length + 12)
      crc = chunk.byteslice(8 + length, 4).unpack1("N")
      raise InvalidLogo, "That PNG file is damaged" unless Zlib.crc32(chunk.byteslice(4, length + 4)) == crc

      check_dimensions!(*chunk.byteslice(8, 8).unpack("N2")) if first
      kept << chunk if PNG_KEEP_CHUNKS.include?(type)
      first = false
      offset = chunk_end
      if type == "IEND"
        seen_end = true
        break
      end
    end
    raise InvalidLogo, "That PNG file is damaged" unless seen_end

    kept.join.b
  end

  def clean_webp(bytes)
    riff_size = bytes.byteslice(4, 4).unpack1("V")
    raise InvalidLogo, "That WebP file is damaged" if riff_size + 8 > bytes.bytesize || riff_size < 12

    offset = 12
    chunks = []
    while offset + 8 <= riff_size + 8
      type = bytes.byteslice(offset, 4)
      length = bytes.byteslice(offset + 4, 4).unpack1("V")
      padded = length + (length.odd? ? 1 : 0)
      raise InvalidLogo, "That WebP file is damaged" if offset + 8 + length > bytes.bytesize

      chunks << [ type, bytes.byteslice(offset, 8 + [ padded, bytes.bytesize - offset - 8 ].min) ]
      offset += 8 + padded
    end
    raise InvalidLogo, "That WebP file is damaged" if chunks.empty?

    check_dimensions!(*webp_dimensions(chunks))
    kept = chunks.reject { |type, _| WEBP_DROP_CHUNKS.include?(type) }.map do |type, chunk|
      next chunk unless type == "VP8X"

      # Clear the EXIF and XMP flags along with their chunks.
      chunk = chunk.dup
      chunk.setbyte(8, chunk.getbyte(8) & ~(WEBP_EXIF_FLAG | WEBP_XMP_FLAG))
      chunk
    end
    body = "WEBP".b + kept.join.b
    ("RIFF".b + [ body.bytesize ].pack("V") + body).b
  end

  def webp_dimensions(chunks)
    type, chunk = chunks.first
    case type
    when "VP8X"
      width = (chunk.byteslice(12, 3) + "\0").unpack1("V") + 1
      height = (chunk.byteslice(15, 3) + "\0").unpack1("V") + 1
      [ width, height ]
    when "VP8 "
      return [] unless chunk.byteslice(11, 3) == "\x9D\x01\x2A".b

      chunk.byteslice(14, 4).unpack("v2").map { |value| value & 0x3FFF }
    when "VP8L"
      return [] unless chunk.getbyte(8) == 0x2F

      bits = chunk.byteslice(9, 4).unpack1("V")
      [ (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1 ]
    else
      []
    end
  end

  def svg_candidate?(bytes)
    head = bytes.byteslice(0, 1024).to_s.force_encoding("UTF-8").scrub.lstrip.downcase
    head.start_with?("<?xml", "<svg", "<!--") && head.include?("<svg")
  end

  def clean_svg(bytes)
    text = bytes.dup.force_encoding("UTF-8")
    raise InvalidLogo, "That SVG file isn't valid text" unless text.valid_encoding?
    raise InvalidLogo, "SVG logos can't include a DOCTYPE or entities" if text.match?(/<!DOCTYPE|<!ENTITY/i)

    document = Nokogiri::XML(text) { |config| config.strict.nonet }
    root = document.root
    unless root&.name == "svg" && root.namespace&.href == SVG_NAMESPACE
      raise InvalidLogo, "That file isn't an SVG image"
    end

    document.xpath("//comment()|//processing-instruction()").each(&:remove)
    # Editor elements such as sodipodi:namedview don't render. Remove them.
    # An XHTML or other document can only render inside foreignObject, which
    # is refused below.
    document.xpath("//*[namespace-uri() != '#{SVG_NAMESPACE}']").each do |node|
      raise InvalidLogo, "That file isn't an SVG image" if node == root
      raise InvalidLogo, SVG_CONTENT_ERROR if node.namespace&.href == "http://www.w3.org/1999/xhtml"

      node.remove
    end
    document.xpath("//svg:*", "svg" => SVG_NAMESPACE).each do |node|
      name = node.name.downcase
      raise InvalidLogo, SVG_CONTENT_ERROR if SVG_FORBIDDEN_ELEMENTS.include?(name)

      node.attribute_nodes.each { |attribute| check_svg_attribute!(attribute) }
      check_svg_style!(node.content) if name == "style"
    end
    document.xpath("//svg:*", "svg" => SVG_NAMESPACE).each do |node|
      node.remove if SVG_DROPPED_ELEMENTS.include?(node.name.downcase)
    end
    check_svg_dimensions!(root)

    document.to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML | Nokogiri::XML::Node::SaveOptions::NO_DECLARATION).strip.b
  rescue Nokogiri::XML::SyntaxError
    raise InvalidLogo, "That SVG file couldn't be read. Export it again as a plain SVG"
  end

  def check_svg_attribute!(attribute)
    namespace = attribute.namespace&.href
    if namespace && !SVG_KEPT_NAMESPACES.include?(namespace)
      # Editor attributes such as inkscape:label or sodipodi:docname.
      attribute.remove
      return
    end

    name = attribute.name.downcase
    value = attribute.value.to_s
    # Only references inside the file itself, such as <use href="#shape">.
    raise InvalidLogo, SVG_CONTENT_ERROR if name == "href" && !value.strip.match?(/\A#[\w.:-]+\z/)
    raise InvalidLogo, SVG_CONTENT_ERROR if name.start_with?("on") || value.match?(/javascript:|data:|url\(\s*['"]?(?!#)/i)

    check_svg_style!(value) if name == "style"
  end

  def check_svg_style!(css)
    return unless css.match?(/@import|expression\(|url\(\s*['"]?(?!#)/i)

    raise InvalidLogo, "SVG logos can't load outside files or fonts. Export a plain SVG or use PNG"
  end

  def check_svg_dimensions!(root)
    view_box = root["viewBox"].to_s.split(/[\s,]+/).map { |value| Float(value, exception: false) }
    width, height = if view_box.size == 4 && view_box.all?
      view_box.last(2)
    else
      [ root["width"], root["height"] ].map { |value| Float(value.to_s[/\A\s*[\d.]+/].to_s, exception: false) }
    end
    return if width.to_f.positive? && height.to_f.positive?

    raise InvalidLogo, "The SVG needs a viewBox or a width and height"
  end
end
