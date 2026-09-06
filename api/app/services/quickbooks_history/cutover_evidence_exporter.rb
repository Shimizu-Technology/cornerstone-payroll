# frozen_string_literal: true

module QuickbooksHistory
  class CutoverEvidenceExporter
    SUPPORTED_EVIDENCE_VERSIONS = [ 1 ].freeze

    attr_reader :filename

    def initialize(review:)
      @review = review
      @filename = "quickbooks_cutover_evidence_batch_#{review.historical_import_batch_id}.xlsx"
    end

    def generate
      raise ArgumentError, "Run cutover verification before exporting evidence" unless review.evidence_passed?
      unless review.evidence.to_h["version"].in?(SUPPORTED_EVIDENCE_VERSIONS)
        raise ArgumentError, "This cutover evidence uses an unsupported version. Re-run cutover verification."
      end

      SpreadsheetReportExporter.new(filename: filename, sheets: sheets).generate
    end

    private

    attr_reader :review

    def sheets
      [
        information_sheet,
        checks_sheet,
        ledger_fingerprints_sheet,
        years_sheet,
        exceptions_sheet,
        attestations_sheet,
        sources_sheet
      ]
    end

    def information_sheet
      batch = review.historical_import_batch
      {
        name: "Cutover information",
        rows: [
          [ "Company", batch.company.name ],
          [ "Historical batch", batch.id ],
          [ "Source", batch.source_label ],
          [ "Bundle SHA-256", batch.bundle_digest ],
          [ "Evidence SHA-256", review.evidence_digest ],
          [ "Verified at", review.verified_at ],
          [ "Verified by", review.verified_by&.name ],
          [ "Cutover status", review.status ],
          [ "Approved at", review.approved_at ],
          [ "Approved by", review.approved_by&.name ],
          [ "Approval notes", review.approval_notes ]
        ],
        column_widths: [ 28, 90 ],
        show_grid_lines: false
      }
    end

    def checks_sheet
      rows = Array(review.evidence["checks"]).map do |check|
        [ check["label"], check["passed"] ? "PASS" : "FAIL" ]
      end
      standard_sheet("Automated checks", [ "Check", "Result" ], rows)
    end

    def years_sheet
      headers = [ "Source pay year", "Paychecks", "Detailed paychecks", "Opening summaries", "Gross pay", "Employee taxes", "Net pay", "Employer taxes", "Total payroll cost" ]
      rows = Array(review.evidence["years"]).map do |year|
        totals = year.fetch("totals")
        [
          year.fetch("year"), year.fetch("paycheck_count"), year.fetch("detailed_paycheck_count"),
          year.fetch("opening_summary_count"), totals.fetch("gross_pay"), totals.fetch("employee_taxes"),
          totals.fetch("net_pay"), totals.fetch("employer_taxes"), totals.fetch("total_payroll_cost")
        ]
      end
      standard_sheet("Year reconciliation", headers, rows)
    end

    def ledger_fingerprints_sheet
      rows = review.evidence.fetch("ledger_digests", {}).map do |record_type, digests|
        [ record_type.to_s.humanize, digests.fetch("source"), digests.fetch("stored"), digests.fetch("source") == digests.fetch("stored") ? "MATCH" : "MISMATCH" ]
      end
      standard_sheet("Ledger fingerprints", [ "Record set", "Fresh source SHA-256", "Stored ledger SHA-256", "Result" ], rows)
    end

    def exceptions_sheet
      rows = Array(review.evidence["exceptions"]).map do |exception|
        [ exception.fetch("message"), review.exception_dispositions.to_h[exception.fetch("key")] ]
      end
      rows << [ "No source limitations or exceptions were reported.", "Not applicable" ] if rows.empty?
      standard_sheet("Exception decisions", [ "Source limitation", "Reviewed decision" ], rows)
    end

    def attestations_sheet
      rows = HistoricalImportCutoverReview::ATTESTATIONS.map do |key, label|
        [ label, ActiveModel::Type::Boolean.new.cast(review.attestations.to_h[key]) ? "CONFIRMED" : "PENDING" ]
      end
      standard_sheet("Cutover checklist", [ "Attestation", "Status" ], rows)
    end

    def sources_sheet
      rows = Array(review.evidence["source_files"]).map do |source|
        [ source.fetch("filename"), source.fetch("report_type"), source.fetch("byte_size"), source.fetch("sha256"), source.fetch("verified") ? "VERIFIED" : "FAILED" ]
      end
      standard_sheet("Retained originals", [ "Filename", "Report type", "Bytes", "SHA-256", "Integrity" ], rows)
    end

    def standard_sheet(name, headers, rows)
      {
        name: name,
        rows: [ headers ] + rows,
        row_style_rules: [ { rows: [ 0 ], style: :header } ],
        styles: { header: { b: true, bg_color: "EAF1F8", fg_color: "172033" } },
        show_grid_lines: false
      }
    end
  end
end
