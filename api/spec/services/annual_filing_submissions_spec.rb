# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFilingEvidenceRecorder do
  let(:company) { create(:company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let(:download) do
    AuditLog.record!(user: actor, company_id: company.id, action: "efw2#download", record_type: "Company",
      metadata: { year: 2026, mode: "final", file_digest: FilingFileDigest.call("final filing bytes"), digest_alg: FilingFileDigest::ALGORITHM, readiness_fingerprint: "a" * 64 })
  end

  before do
    allow_any_instance_of(described_class).to receive(:validate_w2_readiness!)
    allow_any_instance_of(AnnualFilingDownloads).to receive(:fingerprint).and_return("a" * 64)
  end

  def record(agency: "ssa", type: "submitted", **extra)
    described_class.new(company: company, actor: actor, evidence_document: nil, attributes: {
      filing_type: "w2_gu_w3_ss", agency: agency, tax_year: 2026, event_type: type,
      reference_number: "WFID-123", preparer_name: actor.name, idempotency_key: SecureRandom.uuid,
      download_audit_id: type.in?(%w[submitted resubmitted]) ? download.id : nil, **extra
    }).call
  end

  it "tracks each agency independently, binds files and resubmits rejected filings" do
    ssa = record
    drt = record(agency: "drt")
    expect(ssa.payroll_filing_record_id).not_to eq(drt.payroll_filing_record_id)
    expect(ssa.file_digest).to eq(FilingFileDigest.call("final filing bytes"))
    expect(ssa.download_audit_id).to eq(download.id)
    expect(FilingFileDigest.matches?("final filing bytes", ssa.file_digest)).to be(true)
    expect(FilingFileDigest.matches?("different bytes", ssa.file_digest)).to be(false)
    expect(ssa.file_digest).not_to eq(Digest::SHA256.hexdigest("final filing bytes"))
    record(type: "accepted")
    record(agency: "drt", type: "rejected", notes: "Incorrect TIN")
    record(agency: "drt", type: "resubmitted")
    expect(ssa.payroll_filing_record.reload.status).to eq("accepted")
    expect(drt.payroll_filing_record.reload.status).to eq("submitted")
    expect(drt.payroll_filing_record.events.pluck(:event_type)).to eq(%w[submitted rejected resubmitted])
  end

  it "records 1099 DRT only from a final Pub 1220 download and current sign-off" do
    allow(Form1099NecFilingState).to receive(:call).and_return(Form1099NecFilingState::Result.new(
      cornerstone_files: true, report: { reportable_contractors: [ { employee_id: 1 } ] }, readiness: double(marked?: true), final: true))
    allow_any_instance_of(Form1099NecAggregator).to receive(:generate).and_return({ meta: { reportable_count: 1 }, reportable_contractors: [ { compliance_issues: [] } ] })
    allow(InformationReturnThreshold).to receive(:for!).and_return(double(threshold_amount: 600))
    pub = AuditLog.record!(user: actor, company_id: company.id, action: "pub1220#download", record_type: "Company",
      metadata: { year: 2026, mode: "final", file_digest: FilingFileDigest.call("final filing bytes"), digest_alg: FilingFileDigest::ALGORITHM, readiness_fingerprint: "a" * 64 })
    event = record(filing_type: "form_1099_nec", download_audit_id: pub.id)
    expect(event.payroll_filing_record.agency).to eq("drt")
    expect(event.file_digest).to eq(FilingFileDigest.call("final filing bytes"))
  end

  it "refuses legacy unkeyed hashes and unknown digest algorithms" do
    [ download.metadata.except("file_digest", "digest_alg").merge("sha256" => Digest::SHA256.hexdigest("final filing bytes")),
      download.metadata.merge("digest_alg" => "sha256") ].each do |metadata|
      bad = AuditLog.record!(user: actor, company_id: company.id, action: "efw2#download", record_type: "Company", metadata: metadata)
      expect { record(download_audit_id: bad.id) }.to raise_error(described_class::Error, /Choose a final file/)
    end
  end

  it "refuses draft, other-client and other-year downloads" do
    [ { mode: "draft" }, { year: 2025 } ].each do |changes|
      bad = AuditLog.record!(user: actor, company_id: company.id, action: "efw2#download", record_type: "Company", metadata: download.metadata.merge(changes.stringify_keys))
      expect { record(download_audit_id: bad.id) }.to raise_error(described_class::Error, /Choose a final file/)
    end
    other = AuditLog.record!(user: actor, company_id: create(:company).id, action: "efw2#download", record_type: "Company", metadata: download.metadata)
    expect { record(download_audit_id: other.id) }.to raise_error(described_class::Error, /Choose a final file/)
  end

  it "refuses an old fingerprint and an unassigned new submission" do
    allow_any_instance_of(AnnualFilingDownloads).to receive(:fingerprint).and_return("c" * 64)
    expect { record }.to raise_error(described_class::Error, /This file is out of date/)
    expect { record(agency: "legacy") }.to raise_error(described_class::Error, /Choose Social Security/)
  end

  it "allows an outcome after data changed" do
    event = record
    allow_any_instance_of(AnnualFilingDownloads).to receive(:fingerprint).and_return("c" * 64)
    expect { record(type: "accepted") }.not_to raise_error
    expect(event.payroll_filing_record.reload.status).to eq("accepted")
  end
  %w[w2_gu_w3_ss form_1099_nec].each do |filing_type|
    %w[rejected needs_correction].each do |status|
      it "resubmits prior-year #{filing_type} #{status} with a receipt and no file binding" do
        old = PayrollFilingRecord.create!(company: company, filing_type: filing_type, tax_year: 2025,
          status: status, submitted_at: 1.year.ago, confirmation_number: "OLD", source_fingerprint: "a" * 64)
        document = create(:client_document, company: company, uploaded_by: actor, category: "filing_evidence", visible_to_client: false)
        allow(InformationReturnThreshold).to receive(:for!).and_return(double(threshold_amount: 600))
        allow(Form1099NecFilingState).to receive(:call).and_raise("Prior years must not use final sign-off")
        allow_any_instance_of(Form1099NecAggregator).to receive(:generate).and_return({ meta: { reportable_count: 1 }, reportable_contractors: [ { compliance_issues: [] } ] })
        event = described_class.new(company: company, actor: actor, evidence_document: document, attributes: {
          filing_type: filing_type, tax_year: 2025, agency: "ssa", event_type: "resubmitted",
          reference_number: "RETRY", preparer_name: actor.name, signer_name: "Pat Owner", idempotency_key: SecureRandom.uuid
        }).call
        expect(event.payroll_filing_record_id).to eq(old.id)
        expect(event.download_audit_id).to be_nil
        expect(old.reload.status).to eq("submitted")
      end
    end
  end

  it "requires a receipt for prior-year annual evidence" do
    expect { record(tax_year: 2025, download_audit_id: nil) }.to raise_error(described_class::Error, /Evidence must belong/)
  end

  it "names the expected e-file when a PDF download is selected" do
    wrong = AuditLog.record!(user: actor, company_id: company.id, action: "w2#download", record_type: "Company", metadata: download.metadata)
    expect { record(download_audit_id: wrong.id) }.to raise_error(described_class::Error, "That download is not the W-2 e-file")
  end
end
