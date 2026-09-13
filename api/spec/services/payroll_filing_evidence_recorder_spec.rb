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
