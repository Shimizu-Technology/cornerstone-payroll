# frozen_string_literal: true

require "prawn"

# Apply before serialization, including PDFs stored for later download. A large
# center watermark makes sample checks visibly non-negotiable on every page.
module StagingPdfWatermark
  def render(*args, &block)
    if StagingOutboundPolicy.staging? && !@staging_watermarked
      @staging_watermarked = true
      repeat(:all) do
        canvas do
          fill_color "9A3412"
          font("Helvetica", style: :bold) do
            text_box StagingOutboundPolicy::LABEL, at: [ 12, page.dimensions[3] - 12 ], width: page.dimensions[2] - 24, height: 25, size: 11, align: :center
            text_box StagingOutboundPolicy::LABEL, at: [ 12, page.dimensions[3] / 2 ], width: page.dimensions[2] - 24, height: 50, size: 20, align: :center
          end
          fill_color "000000"
        end
      end
    end
    super
  end
end
Prawn::Document.prepend(StagingPdfWatermark)

Rails.application.config.to_prepare do
  ApplicationController.include(StagingArtifactDelivery)
end
