# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::CutoverEvidenceExporter do
  it "exports a multi-sheet, formula-safe evidence workbook without private source data" do
    company = create(:company, name: "Evidence Company")
    actor = create(:user, company: company, organization: company.organization, role: "admin")
    batch = HistoricalImportBatch.create!(
      company: company,
      status: "applied",
      source_label: "=Unsafe source label",
      bundle_digest: SecureRandom.hex(32),
      importer_version: "test"
    )
    review = HistoricalImportCutoverReview.create!(
      company: company,
      historical_import_batch: batch,
      status: "verified",
      evidence: {
        "version" => 1,
        "passed" => true,
        "checks" => [ { "label" => "Stored totals match", "passed" => true } ],
        "ledger_digests" => { "paychecks" => { "source" => "c" * 64, "stored" => "c" * 64 } },
        "years" => [],
        "exceptions" => [],
        "source_files" => [ { "filename" => "+source.xls", "report_type" => "payroll_details", "byte_size" => 10, "sha256" => "b" * 64, "verified" => true } ]
      },
      evidence_digest: "a" * 64,
      verified_at: Time.current,
      verified_by: actor
    )

    workbooks = [ "=Unsafe source label", "+Unsafe source label", "-Unsafe source label", "@Unsafe source label" ].to_h do |source_label|
      batch.update!(source_label: source_label)
      [ source_label, described_class.new(review: review).generate ]
    end
    bytes = workbooks.fetch("=Unsafe source label")

    expect(bytes.byteslice(0, 2)).to eq("PK")
    Zip::File.open_buffer(StringIO.new(bytes)) do |archive|
      workbook = archive.read("xl/workbook.xml")
      sheets = (1..7).map { |index| archive.read("xl/worksheets/sheet#{index}.xml") }
      expect(workbook).to include("Cutover information", "Automated checks", "Ledger fingerprints", "Year reconciliation", "Exception decisions", "Cutover checklist", "Retained originals")
      expect(sheets.join).not_to include("<f>", "private_snapshot", "storage_key")
      expect(sheets.join).to include("&#39;=Unsafe source label", "&#39;+source.xls")
    end
    workbooks.each do |source_label, workbook_bytes|
      Zip::File.open_buffer(StringIO.new(workbook_bytes)) do |archive|
        expect(archive.read("xl/worksheets/sheet1.xml")).to include("&#39;#{source_label}")
      end
    end

    review.update!(evidence: review.evidence.merge("version" => 2))
    expect { described_class.new(review: review).generate }
      .to raise_error(ArgumentError, /unsupported version/)
  end
end
