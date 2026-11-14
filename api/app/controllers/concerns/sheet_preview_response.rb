# frozen_string_literal: true

# Renders a stored spreadsheet as capped sheet tables. Callers authorize and
# load the original bytes exactly as their download action does first.
module SheetPreviewResponse
  extend ActiveSupport::Concern

  private

  def render_sheet_preview(bytes:, filename:)
    preview = SpreadsheetPreview.new(bytes: bytes, filename: filename).call
    yield if block_given?
    render json: { sheet_preview: preview }
  rescue SpreadsheetPreview::Error => e
    render json: { error: e.message, code: "sheet_preview_unavailable" }, status: :unprocessable_entity
  end
end
