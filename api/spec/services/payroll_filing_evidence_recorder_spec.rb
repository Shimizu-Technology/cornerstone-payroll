# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollFilingEvidenceRecorder do
  let(:company) { create(:company) }
  let(:department) { create(:department, company: company) }
  let(:actor) { create(:user, company: company, organization: company.organization, role: "accountant") }
  let(:document) { create(:client_document, company: company, uploaded_by: actor, category: "filing_evidence", visible_to_client: false) }
  let(:source) do
    PayrollFilingSourceSnapshot::Result.new(
      snapshot: { schema_version: "v1", company_id: company.id },
      fingerprint: "a" * 64
    )
  end

  before do
    allow(PayrollFilingSourceSnapshot).to receive(:new).and_return(instance_double(PayrollFilingSourceSnapshot, call: source))
  end

  def ready_quarterly_workflow
    packet = QuarterlyCompliancePacket.find_or_create_for!(company: company, year: 2026, quarter: 2, user: actor)
    packet.quarterly_compliance_tasks.update_all(status: "ready_to_file")
    packet
  end

  def record_event(event_type:, filing_type: "w1", evidence: document, **overrides)
    described_class.new(
      company: company,
      actor: actor,
      evidence_document: evidence,
      attributes: {
        filing_type: filing_type,
        tax_year: 2026,
        quarter: filing_type.in?(PayrollFilingRecord::ANNUAL_TYPES) ? nil : 2,
        event_type: event_type,
        occurred_at: Time.current.iso8601,
        reference_number: "REF-#{SecureRandom.hex(3)}",
        preparer_name: "Dana Accountant",
        signer_name: filing_type == "form_500_payment" ? nil : "Authorized Owner",
        idempotency_key: SecureRandom.uuid,
        **overrides
      }
    ).call
  end

  def ready_w2_workflow
    company.update!(ein: "12-3456789")
    period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 14), pay_date: Date.new(2026, 1, 18))
    employee = create(:employee, company: company, department: department)
    create(:payroll_item, company: company, employee: employee, pay_period: period, gross_pay: 100, reported_tips: 0)
    fingerprint = W2FilingInputsFingerprint.new(company: company, year: 2026).call
    readiness = W2FilingReadiness.create!(company: company, year: 2026, status: "filing_ready",
      preflight_fingerprint: fingerprint, ready_fingerprint: fingerprint, marked_ready_at: Time.current, marked_ready_by: actor)
    [ readiness, employee ]
  end

  it "rejects stale W-2 submission evidence without creating an agency record or event" do
    readiness, employee = ready_w2_workflow
    employee.update!(address_line1: "Changed after filing review")
    expect { record_event(event_type: "submitted", filing_type: "w2_gu_w3_ss") }
      .to raise_error(described_class::Error, /readiness is stale/)
    expect(PayrollFilingRecord.where(company: company)).to be_empty
    expect(PayrollFilingEvent.where(company: company)).to be_empty
    expect(readiness.reload.status).to eq("filing_ready")
  end

  describe "2026 1099-NEC submissions" do
    let!(:contractor) do
      create(:employee, :contractor, company: company, department: department, ssn_encrypted: "345-67-7890",
        address_line1: "7 Route 8", city: "Maite", state: "GU", zip: "96910")
    end

    before do
      create(:information_return_threshold, tax_year: 2026, threshold_amount: 2_000)
      period = create(:pay_period, :committed, company: company, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 14), pay_date: Date.new(2026, 5, 18))
      create(:payroll_item, company: company, employee: contractor, pay_period: period, employment_type: "contractor", gross_pay: 2_500, withholding_tax: 0)
      create(:payroll_filing_responsibility, :annual, company: company, filing_type: "form_1099", responsible_party: "cornerstone", source_cutoff_date: nil)
    end

    def mark_ready
      fingerprint = Form1099InputsFingerprint.new(company: company.reload, year: 2026).call
      Form1099FilingReadiness.find_or_initialize_by(company: company, tax_year: 2026)
        .update!(ready_fingerprint: fingerprint, marked_ready_at: Time.current, marked_ready_by: actor, marked_ready_by_name: actor.name)
    end

    it "needs the 1099s marked ready on the current inputs" do
      expect { record_event(event_type: "submitted", filing_type: "form_1099_nec") }.to raise_error(described_class::Error, /Mark the 2026 1099s ready/)

      mark_ready
      contractor.update_columns(zip: "96911")
      expect { record_event(event_type: "submitted", filing_type: "form_1099_nec") }.to raise_error(described_class::Error, /changed after they were marked ready/)
      expect(PayrollFilingRecord.where(company: company)).to be_empty

      mark_ready
      download = AuditLog.record!(user: actor, company_id: company.id, action: "pub1220#download", record_type: "Company",
        metadata: { year: 2026, mode: "final", readiness_fingerprint: Form1099InputsFingerprint.new(company: company.reload, year: 2026).call }.merge(FilingFileDigest.audit_metadata("final 1099 bytes")))
      expect(record_event(event_type: "submitted", filing_type: "form_1099_nec", download_audit_id: download.id).payroll_filing_record.filing_type).to eq("form_1099_nec")
    end

    it "refuses evidence in a year with no 1099s, with the checklist's message" do
      contractor.payroll_items.sole.update_columns(gross_pay: 1_500)

      expect { record_event(event_type: "submitted", filing_type: "form_1099_nec") }.to raise_error(described_class::Error, "No 1099s to file for 2026")
      expect(PayrollFilingRecord.where(company: company)).to be_empty
    end
  end

  it "accepts evidence for current revalidated W-2 inputs" do
    ready_w2_workflow
    download = AuditLog.record!(user: actor, company_id: company.id, action: "efw2#download", record_type: "Company",
      metadata: { year: 2026, mode: "final", file_digest: FilingFileDigest.call("final filing bytes"), digest_alg: FilingFileDigest::ALGORITHM, readiness_fingerprint: W2FilingInputsFingerprint.new(company: company, year: 2026).call })
    event = record_event(event_type: "submitted", filing_type: "w2_gu_w3_ss", agency: "ssa", download_audit_id: download.id)
    expect(event.event_type).to eq("submitted")
    expect(event.payroll_filing_record.filing_type).to eq("w2_gu_w3_ss")
  end

  it "records submission and later acceptance as an append-only evidence timeline" do
    ready_quarterly_workflow

    submitted = record_event(event_type: "submitted")
    accepted = record_event(event_type: "accepted")

    filing = submitted.payroll_filing_record.reload
    expect(filing).to have_attributes(status: "accepted", confirmation_number: accepted.reference_number)
    expect(filing.events.pluck(:event_type)).to eq(%w[submitted accepted])
    expect(filing.events.pluck(:evidence_document_id)).to all(eq(document.id))
    expect(filing.source_fingerprint).to eq("a" * 64)
  end

  it "normalizes optional signer fields before retaining evidence" do
    ready_quarterly_workflow

    event = record_event(
      event_type: "submitted",
      signer_name: "  Authorized Owner  ",
      signer_title: "  President  "
    )

    expect(event).to have_attributes(signer_name: "Authorized Owner", signer_title: "President")
  end

  it "does not let an outcome create a filing that was never submitted" do
    expect { record_event(event_type: "accepted") }
      .to raise_error(described_class::Error, "The first event must record the submission")
  end

  it "requires the Form 941 task and Schedule B attachment to be ready together" do
    packet = ready_quarterly_workflow
    packet.quarterly_compliance_tasks.find_by!(task_type: "schedule_b").update_column(:status, "needs_review")

    expect { record_event(event_type: "submitted", filing_type: "federal_941") }
      .to raise_error(described_class::Error, /Mark Schedule b ready/)
  end

  it "requires retained internal evidence from the same company" do
    ready_quarterly_workflow
    public_document = create(:client_document, company: company, uploaded_by: actor, category: "filing_evidence", visible_to_client: true)

    expect { record_event(event_type: "submitted", evidence: public_document) }
      .to raise_error(described_class::Error, /retained as an internal document/)
  end

  it "does not accept an unrelated internal document as filing evidence" do
    ready_quarterly_workflow
    unrelated_document = create(:client_document, company: company, uploaded_by: actor, category: "misc", visible_to_client: false)

    expect { record_event(event_type: "submitted", evidence: unrelated_document) }
      .to raise_error(described_class::Error, "Choose a filing-evidence document")
  end

  it "requires the primary quarterly task to be ready rather than not required" do
    packet = ready_quarterly_workflow
    packet.quarterly_compliance_tasks.find_by!(task_type: "w1").update_column(:status, "not_required")

    expect { record_event(event_type: "submitted") }
      .to raise_error(described_class::Error, "Mark W1 ready before recording the submission")
  end

  it "requires a stable idempotency key" do
    ready_quarterly_workflow

    expect { record_event(event_type: "submitted", idempotency_key: nil) }
      .to raise_error(described_class::Error, "Idempotency key is required")
  end

  it "preserves a rejection and permits a corrected resubmission with a fresh source fingerprint" do
    ready_quarterly_workflow
    record_event(event_type: "submitted")
    record_event(event_type: "rejected", notes: "Agency rejected the account identifier")
    replacement_source = PayrollFilingSourceSnapshot::Result.new(snapshot: { schema_version: "v1", revision: 2 }, fingerprint: "b" * 64)
    allow(PayrollFilingSourceSnapshot).to receive(:new).and_return(instance_double(PayrollFilingSourceSnapshot, call: replacement_source))

    record_event(event_type: "resubmitted")

    filing = PayrollFilingRecord.last
    expect(filing.status).to eq("submitted")
    expect(filing.source_fingerprint).to eq("b" * 64)
    expect(filing.events.pluck(:event_type)).to eq(%w[submitted rejected resubmitted])
  end

  it "preserves a correction trail when a previously accepted filing must be amended" do
    ready_quarterly_workflow
    record_event(event_type: "submitted")
    record_event(event_type: "accepted")
    record_event(event_type: "correction_needed", notes: "A later payroll correction changed taxable wages")
    record_event(event_type: "resubmitted")

    filing = PayrollFilingRecord.last
    expect(filing.status).to eq("submitted")
    expect(filing.events.pluck(:event_type)).to eq(%w[submitted accepted correction_needed resubmitted])
  end

  it "rejects an event timestamp earlier than the retained filing history" do
    ready_quarterly_workflow
    original_time = 2.hours.ago.change(usec: 0)
    record_event(event_type: "submitted", occurred_at: original_time.iso8601)

    expect { record_event(event_type: "accepted", occurred_at: (original_time - 1.minute).iso8601) }
      .to raise_error(described_class::Error, "Event date and time cannot be before the previous filing event")
  end

  it "prevents filing evidence from being edited or deleted" do
    ready_quarterly_workflow
    event = record_event(event_type: "submitted")

    expect(event.update(notes: "changed")).to be(false)
    expect(event.errors.full_messages).to include("Filing evidence history is append-only")
    expect(event.destroy).to be(false)
  end

  it "rejects direct SQL updates at the database boundary" do
    ready_quarterly_workflow
    event = record_event(event_type: "submitted")

    expect do
      PayrollFilingEvent.connection.execute(
        "UPDATE payroll_filing_events SET notes = 'rewritten' WHERE id = #{Integer(event.id)}"
      )
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "rejects direct SQL deletes at the database boundary" do
    ready_quarterly_workflow
    event = record_event(event_type: "submitted")

    expect do
      PayrollFilingEvent.connection.execute(
        "DELETE FROM payroll_filing_events WHERE id = #{Integer(event.id)}"
      )
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end
end
