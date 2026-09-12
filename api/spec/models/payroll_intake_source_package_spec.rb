# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Payroll intake source package evidence" do
  let!(:session) { create(:payroll_intake_session, status: "draft") }
  let!(:document) do
    session.documents.create!(
      document_type: "pasted_text",
      source_role: "pasted_email",
      position: 0,
      text_content: "authoritative payroll email",
      byte_size: 27,
      sha256: Digest::SHA256.hexdigest("authoritative payroll email"),
      verification_status: "verified",
      verified_at: Time.current
    )
  end

  before { session.update!(status: "previewed") }

  it "does not allow package identity to be rewritten" do
    expect(session.update(import_hash: Digest::SHA256.hexdigest("replacement"))).to be(false)
    expect(session.errors.full_messages).to include("Payroll source package identity cannot be changed")
  end

  it "does not allow a source to be added after preview or the package to be deleted" do
    extra = session.documents.build(
      document_type: "pasted_text",
      source_role: "supporting_document",
      position: 1,
      text_content: "late source"
    )

    expect(extra).not_to be_valid
    expect(extra.errors.full_messages).to include("Sources cannot be added after the payroll package is previewed")
    expect(session.destroy).to be(false)
    expect(session).to be_persisted
  end

  it "does not allow retained source evidence to be rewritten or deleted" do
    expect(document.update(text_content: "changed")).to be(false)
    expect(document.errors.full_messages).to include("Payroll source document evidence cannot be changed")
    expect(document.destroy).to be(false)
    expect(document).to be_persisted
  end

  it "detects content that no longer matches the recorded fingerprint" do
    document.update_column(:text_content, "tampered")

    expect {
      PayrollIntake::SourcePackageVerifier.new(session: session).verify!
    }.to raise_error(PayrollIntake::SourcePackageVerifier::VerificationError, /no longer matches/)
    expect(document.reload).to have_attributes(
      verification_status: "failed",
      verification_error: "Stored source failed integrity verification"
    )
  end

  it "keeps an auditable correction chain and makes only the replacement applyable" do
    session.mark_superseded!(actor: session.created_by)
    successor = create(
      :payroll_intake_session,
      company: session.company,
      pay_period: session.pay_period,
      source_type: session.source_type,
      source_label: session.source_label,
      package_revision: session.package_revision + 1,
      supersedes: session,
      supersession_reason: "Client corrected the hours attachment."
    )

    expect(session.reload).to be_superseded
    expect(session).not_to be_applyable
    expect(successor.reload).to be_current
    expect(successor).to be_applyable
    expect(successor.supersession_reason).to eq("Client corrected the hours attachment.")
    expect(session.replacement_session).to eq(successor)
  end

  it "rejects a replacement that does not point to the current package for the same source" do
    other_period = create(:pay_period, company: session.company)
    invalid = build(
      :payroll_intake_session,
      company: session.company,
      pay_period: other_period,
      source_type: session.source_type,
      package_revision: session.package_revision + 1,
      supersedes: session,
      supersession_reason: "Wrong period"
    )

    expect(invalid).not_to be_valid
    expect(invalid.errors.full_messages).to include(
      "Supersedes must be the newly superseded earlier package for this pay period and source"
    )
  end

  it "requires complete, attributed row outcomes" do
    row = build(:payroll_intake_row, payroll_intake_session: session, disposition: "excluded")

    expect(row).not_to be_valid
    expect(row.errors[:dispositioned_at]).to include("must be recorded")
    expect(row.errors[:disposition_reason]).to include("is required for this outcome")
  end
end
