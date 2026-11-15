# frozen_string_literal: true

# Renders a stored spreadsheet as capped sheet tables. Callers authorize and
# load the original bytes exactly as their download action does first. A file
# that cannot be shown is still a preview answer: the reason is returned so the
# viewer can explain it beside the download button.
module SheetPreviewResponse
  extend ActiveSupport::Concern

  private

  def render_sheet_preview(bytes:, filename:)
    preview = SpreadsheetPreview.new(bytes: bytes, filename: filename).call
    yield if block_given?
    render json: { sheet_preview: preview }
  rescue SpreadsheetPreview::Error => e
    render json: { sheet_preview: nil, sheet_preview_unavailable: e.message }
  end
end
