# frozen_string_literal: true

# Renders an invoice snapshot to PDF bytes.
#
# The theme comes from the snapshot's recorded "style", never from the live
# billing profile, so a re-render of an issued invoice keeps the look it was
# issued with. Snapshots recorded before themes existed carry no style and
# use the legacy layout. Drafts are snapshotted fresh from the profile, so a
# draft preview always shows the profile's current style.
class InvoicePdfGenerator
  RENDERERS = {
    InvoicePdf::Style::LEGACY => InvoicePdf::Renderers::Legacy,
    "classic" => InvoicePdf::Renderers::Classic,
    "modern" => InvoicePdf::Renderers::Modern,
    "professional" => InvoicePdf::Renderers::Professional,
    "banner" => InvoicePdf::Renderers::Banner
  }.freeze
  LEGACY_RENDERER_VERSION = "prawn-v2"
  THEMED_RENDERER_VERSION = "prawn-themes-v1"
  NO_LOGO = Object.new.freeze

  # logo: raw image bytes to use instead of the snapshot's stored logo, or
  # InvoicePdfGenerator::NO_LOGO to draw the monogram. Used by the style
  # preview, which shows a logo the operator has chosen but not yet saved.
  def initialize(invoice, snapshot: nil, logo: nil)
    @invoice = invoice
    @snapshot = snapshot.presence || invoice&.snapshot.presence || invoice&.draft_snapshot
    raise ArgumentError, "An invoice snapshot is required" if @snapshot.blank?

    @logo_override = logo
  end

  def filename
    number = data.display_number.to_s.parameterize.presence || "invoice"
    "invoice-#{number}.pdf"
  end

  def style
    @style ||= InvoicePdf::Style.from_snapshot(snapshot)
  end

  def theme
    style.theme
  end

  def renderer_version
    style.legacy? ? LEGACY_RENDERER_VERSION : THEMED_RENDERER_VERSION
  end

  def template_version
    style.template_version
  end

  def generate
    RENDERERS.fetch(theme).new(data: data, style: style, logo: logo_bytes).render
  end

  private

  attr_reader :snapshot

  def data
    @data ||= InvoicePdf::InvoiceData.new(snapshot)
  end

  def logo_bytes
    return nil if @logo_override.equal?(NO_LOGO)
    return @logo_override if @logo_override.present?
    return nil if data.billing["logo_storage_key"].blank?

    InvoiceLogoStorageService.new.download(data.billing)
  end
end
