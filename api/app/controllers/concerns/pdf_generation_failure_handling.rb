# frozen_string_literal: true

# A PDF that cannot be built returns a clear JSON error instead of an
# unhandled 500. Unhandled exceptions can reach the browser without CORS
# headers, which the web app can only report as a dropped connection.
module PdfGenerationFailureHandling
  extend ActiveSupport::Concern

  MESSAGE = "We couldn't create this PDF. Try again. " \
            "If it keeps failing, use the Excel or CSV version where one is offered " \
            "and contact support with the name of the document."

  def self.prawn_errors
    Prawn::Errors.constants.filter_map do |name|
      error = Prawn::Errors.const_get(name)
      error if error.is_a?(Class) && error <= StandardError
    end
  end

  included do
    rescue_from(*PdfGenerationFailureHandling.prawn_errors, with: :render_pdf_generation_failure)
    rescue_from(PdfUnicodeFont::UnprintableName) do |error|
      render json: { error: error.message, code: "unprintable_name" }, status: :unprocessable_entity
    end
  end

  private

  def render_pdf_generation_failure(error)
    Rails.logger.error("[PDF] #{controller_path}##{action_name} failed: #{error.class}: #{error.message}")
    render json: { error: MESSAGE, code: "pdf_generation_failed" }, status: :internal_server_error
  end
end
