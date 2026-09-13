# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeDocumentRequirementReviewService do
  let(:company) { create(:company) }
  let(:employee) { create(:employee, company: company) }
  let(:actor) { create(:user, company: company, role: "admin") }
  let(:document) { create(:client_document, company: company, employee: employee, uploaded_by: actor) }
  let(:requirement) do
    create(
      :employee_document_requirement,
      company: company,
      employee: employee,
      client_document: document,
      status: "received",
      received_at: Time.current
    )
  end

  it "records a verified outcome with reviewer evidence" do
    described_class.new(
      requirement: requirement,
      actor: actor,
      attributes: {
        status: "verified",
        client_document_id: document.id,
        review_note: "Matched the signed form to the employee record.",
        lock_version: requirement.lock_version
      }
    ).call!

    expect(requirement.reload).to have_attributes(
      status: "verified",
      reviewed_by: actor,
      review_note: "Matched the signed form to the employee record."
    )
    expect(requirement.reviewed_at).to be_present
    expect(requirement.events.sole).to have_attributes(
      event_type: "status_changed",
      from_status: "received",
      to_status: "verified",
      actor: actor,
      document_title: document.title,
      note: "Matched the signed form to the employee record."
    )
  end

  it "keeps readiness events append-only" do
    described_class.new(
      requirement: requirement,
      actor: actor,
      attributes: {
        status: "verified",
        review_note: "Matched the signed form to the employee record.",
        lock_version: requirement.lock_version
      }
    ).call!
    event = requirement.events.sole

    expect(event.update(note: "Rewritten")).to be(false)
    expect(event.errors.full_messages).to include("Employee document readiness history is append-only")
    expect(event.reload.note).to eq("Matched the signed form to the employee record.")
  end

  it "does not carry a prior reviewed note into a received event" do
    requirement.update!(
      status: "verified",
      reviewed_by: actor,
      reviewed_at: Time.current,
      review_note: "Earlier verification"
    )

    described_class.new(
      requirement: requirement,
      actor: actor,
      attributes: {
        status: "received",
        review_note: "Earlier verification",
        lock_version: requirement.lock_version
      }
    ).call!

    expect(requirement.reload.review_note).to be_nil
    expect(requirement.events.sole).to have_attributes(
      from_status: "verified",
      to_status: "received",
      note: nil
    )
  end

  it "requires a reason for verified, rejected, and waived outcomes" do
    expect do
      described_class.new(
        requirement: requirement,
        actor: actor,
        attributes: { status: "verified", lock_version: requirement.lock_version }
      ).call!
    end.to raise_error(described_class::Error, /Explain the reviewed outcome/)
  end

  it "rejects stale checklist versions" do
    requirement.update!(received_at: 1.minute.ago)

    expect do
      described_class.new(
        requirement: requirement,
        actor: actor,
        attributes: { status: "received", lock_version: requirement.lock_version - 1 }
      ).call!
    end.to raise_error(ActiveRecord::StaleObjectError)
  end

  it "does not attach another employee's document" do
    other_document = create(:client_document, company: company, employee: create(:employee, company: company), uploaded_by: actor)

    expect do
      described_class.new(
        requirement: requirement,
        actor: actor,
        attributes: {
          status: "verified",
          client_document_id: other_document.id,
          review_note: "Wrong employee",
          lock_version: requirement.lock_version
        }
      ).call!
    end.to raise_error(described_class::Error, /does not belong to this employee/)
  end
end
