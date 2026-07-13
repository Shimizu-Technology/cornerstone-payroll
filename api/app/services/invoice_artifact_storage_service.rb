# frozen_string_literal: true

require "digest"
require "marcel"

class InvoiceArtifactStorageService
  MAX_FILE_SIZE = 15.megabytes
  IMPORT_CONTENT_TYPES = %w[application/pdf image/jpeg image/png image/webp].freeze
  RENDERER_VERSION = "prawn-v2"
  TEMPLATE_VERSION = "standard-v2"

  def initialize(storage: R2StorageService.new)
    @storage = storage
  end

  def issue_native!(invoice:, actor:)
    if invoice.line_items.reject(&:marked_for_destruction?).empty?
      invoice.errors.add(:line_items, "must include at least one line item")
      raise ActiveRecord::RecordInvalid, invoice
    end

    snapshot = invoice.issued_snapshot(actor: actor)
    pdf_bytes = InvoicePdfGenerator.new(invoice, snapshot: snapshot).generate

    store_and_issue!(
      invoice: invoice,
      actor: actor,
      bytes: pdf_bytes,
      filename: "#{invoice.invoice_number}.pdf",
      content_type: "application/pdf",
      kind: "issued_pdf",
      snapshot: snapshot,
      renderer_version: RENDERER_VERSION,
      template_version: TEMPLATE_VERSION
    )
  end

  def import_original!(invoice:, actor:, file:, issued_at: Time.current)
    bytes, content_type, filename = validate_import!(file)

    store_and_issue!(
      invoice: invoice,
      actor: actor,
      bytes: bytes,
      filename: filename,
      content_type: content_type,
      kind: "imported_original",
      snapshot: invoice.issued_snapshot(actor: actor, issued_at: issued_at),
      issued_at: issued_at,
      renderer_version: nil,
      template_version: nil
    )
  end

  def download(artifact)
    storage.download(artifact.storage_key)
  end

  private

  attr_reader :storage

  def validate_import!(file)
    raise ArgumentError, "Invoice file is required" unless file
    raise ArgumentError, "Invoice file exceeds the 15 MB limit" if file.size.to_i > MAX_FILE_SIZE

    file.tempfile.rewind
    content_type = Marcel::MimeType.for(file.tempfile, name: file.original_filename)
    file.tempfile.rewind
    raise ArgumentError, "Invoice file must be a PDF, JPEG, PNG, or WebP" unless IMPORT_CONTENT_TYPES.include?(content_type)

    bytes = file.tempfile.read
    file.tempfile.rewind
    raise ArgumentError, "Invoice file is empty" if bytes.blank?

    [ bytes, content_type, sanitized_filename(file.original_filename, content_type) ]
  end

  def store_and_issue!(invoice:, actor:, bytes:, filename:, content_type:, kind:, snapshot:, issued_at: Time.current,
                       renderer_version:, template_version:)
    key = storage_key(invoice: invoice, filename: filename)
    storage.upload(key, StringIO.new(bytes), content_type: content_type)

    Invoice.transaction do
      locked_invoice = Invoice.lock.find(invoice.id)
      raise ActiveRecord::RecordInvalid, locked_invoice unless locked_invoice.draft?

      artifact = locked_invoice.artifacts.create!(
        organization: locked_invoice.organization,
        kind: kind,
        storage_key: key,
        filename: filename,
        content_type: content_type,
        byte_size: bytes.bytesize,
        sha256: Digest::SHA256.hexdigest(bytes),
        renderer_version: renderer_version,
        template_version: template_version,
        created_by: actor
      )
      locked_invoice.issue!(actor: actor, snapshot: snapshot, issued_at: issued_at)
      InvoiceEvent.record!(
        invoice: locked_invoice,
        event_type: kind == "imported_original" ? "imported" : "issued",
        actor: actor,
        occurred_at: issued_at,
        metadata: { artifact_id: artifact.id, sha256: artifact.sha256, filename: artifact.filename }
      )
      artifact
    end
  rescue StandardError
    storage.delete(key) if key.present?
    raise
  end

  def storage_key(invoice:, filename:)
    extension = File.extname(filename).downcase.presence || ".bin"
    "invoice-center/organization-#{invoice.organization_id}/invoice-#{invoice.id}/#{SecureRandom.uuid}#{extension}"
  end

  def sanitized_filename(filename, content_type)
    basename = File.basename(filename.to_s).gsub(/[^a-zA-Z0-9._-]/, "_").presence || "invoice"
    return basename if File.extname(basename).present?

    extension = {
      "application/pdf" => ".pdf",
      "image/jpeg" => ".jpg",
      "image/png" => ".png",
      "image/webp" => ".webp"
    }.fetch(content_type)
    "#{basename}#{extension}"
  end
end
