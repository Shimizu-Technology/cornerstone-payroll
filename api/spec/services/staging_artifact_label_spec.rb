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
    expect(described_class.mark("Employee,Hours\nSynthetic,8", filename: "sample.csv")).to start_with(StagingOutboundPolicy::LABEL.b)
    expect { described_class.mark("government file", filename: "efw2.txt") }.to raise_error(StagingOutboundPolicy::Blocked)
  end

  it "leaves non-staging artifact bytes intact" do
    ENV["DEPLOYMENT_ENV"] = "production"
    expect(described_class.mark("original", filename: "efw2.txt")).to eq("original")
  end
  it "preserves non-ASCII binary CSV bytes after the warning" do
    original = "Name,Pay\nJos\xC3\xA9,1\n".b
    marked = described_class.mark(original, filename: "employees.csv")
    expect(marked.b).to eq(StagingOutboundPolicy::LABEL.b + "\n".b + original)
  end

  it "marks every real ZIP member and includes the archive notice" do
    require "zip"
    original = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("reports/people.csv")
      zip.write("Name\nSynthetic")
      zip.put_next_entry("check.pdf")
      zip.write(Prawn::Document.new { text "Synthetic" }.render)
    end.string
    marked = described_class.mark(original, filename: "reports.zip")
    Zip::File.open_buffer(marked) do |zip|
      expect(zip.map(&:name)).to contain_exactly("STAGING_reports/people.csv", "STAGING_check.pdf", "STAGING_DO_NOT_ISSUE_OR_FILE.txt")
      expect(zip.read("STAGING_reports/people.csv")).to start_with(StagingOutboundPolicy::LABEL.b)
      expect(PDF::Reader.new(StringIO.new(zip.read("STAGING_check.pdf"))).pages.first.text).to include(StagingOutboundPolicy::LABEL)
      expect(zip.read("STAGING_DO_NOT_ISSUE_OR_FILE.txt")).to eq(StagingOutboundPolicy::LABEL.b)
    end
  end

  it "holds an entire ZIP containing any unsupported member" do
    require "zip"
    original = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("bank.ach")
      zip.write("machine submittable")
    end.string
    expect { described_class.mark(original, filename: "bank.zip") }.to raise_error(StagingOutboundPolicy::Blocked)
  end

  it "places the watermark within each mixed-size page when rendered directly" do
    document = Prawn::Document.new(page_size: "LETTER")
    document.text "Portrait"
    document.start_new_page(size: "LEGAL", layout: :landscape)
    document.text "Landscape"
    document.start_new_page(size: [ 300, 400 ])
    document.text "Small"
    pages = PDF::Reader.new(StringIO.new(document.render)).pages
    pages.each do |page|
      expect(page.text).to include(StagingOutboundPolicy::LABEL)
      width = page.attributes[:MediaBox][2]
      height = page.attributes[:MediaBox][3]
      positions = page.runs.select { |run| run.text.include?("STAGING") }
      expect(positions).not_to be_empty
      expect(positions.any? { |run| run.y.between?(height - 50, height) }).to eq(true)
      positions.each do |run|
        expect(run.x).to be_between(0, width)
        expect(run.y).to be_between(0, height)
      end
    end
  end
end
