# frozen_string_literal: true

module StagingArtifactDelivery
  extend ActiveSupport::Concern

  def send_data(data, options = {})
    return super unless StagingOutboundPolicy.staging?
    filename = options[:filename].to_s
    marked = StagingArtifactLabel.mark(data, filename: filename, type: options[:type])
    super(marked, options.merge(filename: "STAGING_#{filename}"))
  end

  def send_file(path, options = {})
    return super unless StagingOutboundPolicy.staging?
    send_data(File.binread(path), options.merge(filename: options[:filename] || File.basename(path)))
  end
end
