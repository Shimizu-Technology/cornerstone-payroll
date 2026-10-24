# frozen_string_literal: true

require "rails_helper"
require "pdf/reader"

RSpec.describe StagingArtifactLabel do
  around do |example|
    old = ENV["DEPLOYMENT_ENV"]
    ENV["DEPLOYMENT_ENV"] = "staging"
    example.run
  ensure
    old ? ENV["DEPLOYMENT_ENV"] = old : ENV.delete("DEPLOYMENT_ENV")
  end

  it "marks every page of a generated report/check/stub" do
    document = Prawn::Document.new
    document.text "Synthetic check"
    document.start_new_page
    document.text "Synthetic stub"
    bytes = described_class.mark(document.render, filename: "sample.pdf", type: "application/pdf")
    pages = PDF::Reader.new(StringIO.new(bytes)).pages
    expect(pages.size).to eq(2)
    pages.each { |page| expect(page.text).to include(StagingOutboundPolicy::LABEL) }
  end

  it "labels CSV content and holds machine-submittable filing formats" do
    expect(described_class.mark("Employee,Hours\nSynthetic,8", filename: "sample.csv")).to start_with(StagingOutboundPolicy::LABEL)
    expect { described_class.mark("government file", filename: "efw2.txt") }.to raise_error(StagingOutboundPolicy::Blocked)
  end

  it "leaves non-staging artifact bytes intact" do
    ENV["DEPLOYMENT_ENV"] = "production"
    expect(described_class.mark("original", filename: "efw2.txt")).to eq("original")
  end
end
