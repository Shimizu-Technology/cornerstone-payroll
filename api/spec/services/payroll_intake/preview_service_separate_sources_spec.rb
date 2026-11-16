# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::PreviewService, "separate MoSa source files" do
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:run) { create(:pay_period, company: company) }
  let!(:actor) { create(:user, company: company, role: "admin") }
  let!(:employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example") }
  let(:objects) { {} }
  let(:storage) do
    entries = objects
    Object.new.tap do |store|
      store.define_singleton_method(:upload) { |key, data, **| entries[key] = data }
      store.define_singleton_method(:download_with_limit) { |key, **| entries.fetch(key) }
      store.define_singleton_method(:delete) { |key| entries.delete(key) }
    end
  end
  let(:pdf_bytes) { revel_bytes(40) }
  let(:workbook_bytes) { PayrollImport::MosaSupplementalTemplate.new(run).generate }

  before do
    CompanyWorkweek.create!(company: company, starts_on_weekday: run.start_date.wday, starts_at_minutes: 0,
      timezone: "Pacific/Guam", effective_on: run.start_date, source: "operator_confirmed", confirmation_status: "confirmed",
      confirmed_by: actor, confirmed_at: Time.current, notes: "Synthetic workweek")
  end

  def revel_bytes(hours)
    File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: hours, regular_pay: hours * 10 } ],
      period_start: run.start_date, period_end: run.end_date))
  end

  def pdf(bytes = pdf_bytes) = portal_upload("revel.pdf", bytes, "application/pdf")
  def workbook(bytes = workbook_bytes) = portal_upload("changes.xlsx", bytes, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")

  def preview(*files, **options)
    described_class.new(pay_period: run, source_type: "mosa_revel", actor: actor, storage: storage,
      files: files, carry_forward: true, **options).call
  end

  def roles(session) = session.documents.in_package_order.map(&:source_role)

  it "adds the workbook to a PDF-only package without a replacement reason" do
    first = preview(pdf).fetch(:session)
    expect(roles(first)).to eq([ "revel_hours" ])

    second = preview(workbook).fetch(:session)

    expect(second).to have_attributes(supersedes_id: first.id, supersession_reason: "Added: Tips & loans workbook", package_revision: 2)
    expect(roles(second)).to eq(%w[revel_hours supplemental_workbook])
    expect(first.reload).to be_superseded
    carried = second.documents.find_by!(source_role: "revel_hours")
    original = first.documents.find_by!(source_role: "revel_hours")
    # The carried PDF is the same evidence, re-verified and stored as this package's own copy.
    expect(carried).to have_attributes(sha256: original.sha256, verification_status: "verified")
    expect(carried.storage_reference).not_to eq(original.storage_reference)
    expect(carried.metadata).to include("carried_from_document_id" => original.id)
    expect(second.evidence_snapshot.fetch("source_changes")).to include(
      "added" => [ "supplemental_workbook" ], "replaced" => [],
      "carried" => [ include("role" => "revel_hours", "document_id" => original.id, "sha256" => original.sha256) ]
    )
    expect(second.rows.find_by!(employee: employee).regular_hours).to eq(40)
    expect(run.reload.intake_stale_at).to be_nil
  end

  it "adds the PDF to a workbook-only package and matches the whole package again" do
    first = preview(workbook).fetch(:session)
    expect(roles(first)).to eq([ "supplemental_workbook" ])

    second = preview(pdf).fetch(:session)

    expect(second).to have_attributes(supersedes_id: first.id, supersession_reason: "Added: Revel hours PDF")
    expect(roles(second)).to eq(%w[revel_hours supplemental_workbook])
    expect(second.rows.find_by!(employee: employee).regular_hours).to eq(40)
  end

  it "gives a package completed in two steps the same identity as one uploaded at once" do
    combined = preview(pdf).then { preview(workbook) }.fetch(:session)

    expect(preview(pdf, workbook)).to include(duplicate: true, session: combined)
    expect(preview(workbook)).to include(duplicate: true, session: combined)
  end

  it "still requires a reason to replace a file already received, and keeps the other file" do
    first = preview(pdf, workbook).fetch(:session)
    corrected = revel_bytes(38)

    expect { preview(pdf(corrected)) }.to raise_error(described_class::ReplacementRequiredError, /replaces revision 1/)
    expect { preview(pdf(corrected), supersedes_package_id: first.package_id) }.to raise_error(described_class::ReplacementRequiredError, /Enter why/)

    second = preview(pdf(corrected), supersedes_package_id: first.package_id, supersession_reason: "MoSa corrected Avery's hours").fetch(:session)

    expect(second).to have_attributes(supersedes_id: first.id, supersession_reason: "MoSa corrected Avery's hours")
    expect(roles(second)).to eq(%w[revel_hours supplemental_workbook])
    expect(second.documents.find_by!(source_role: "supplemental_workbook").sha256).to eq(Digest::SHA256.hexdigest(workbook_bytes))
    expect(second.evidence_snapshot.fetch("source_changes")).to include("added" => [], "replaced" => [ "revel_hours" ])
    expect(second.rows.find_by!(employee: employee).regular_hours).to eq(38)
  end

  it "requires a reason to add a file to a package that was already applied" do
    first = preview(pdf).fetch(:session)
    first.mark_applied!(actor: actor)

    expect { preview(workbook) }.to raise_error(described_class::ReplacementRequiredError)
    expect(PayrollIntakeSession.count).to eq(1)
  end

  it "re-runs matching for the same files after a worker returns, without a reason" do
    returning = create(:employee, company: company, first_name: "Blake", last_name: "Returning", status: "inactive")
    returning_pdf = File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, regular_pay: 400 },
      { name: "Returning, Blake", regular_hours: 12, regular_pay: 120 } ], period_start: run.start_date, period_end: run.end_date))
    first = preview(pdf(returning_pdf), workbook).fetch(:session)
    expect(first.rows.map(&:employee_id)).not_to include(returning.id)

    expect(preview).to include(duplicate: true, session: first)

    EmployeeStatusTransitionService.reactivate!(employee: returning, actor: actor, attributes: { effective_date: run.start_date.iso8601 })
    second = preview.fetch(:session)

    expect(second).to have_attributes(supersedes_id: first.id, supersession_reason: "Matched the same files again after the employee list changed")
    expect(second.documents.pluck(:sha256)).to match_array(first.documents.pluck(:sha256))
    expect(second.rows.find_by!(employee: returning).regular_hours).to eq(12)
  end

  it "removes a file with the given reason, and can add it back after returning to a superseded version's files" do
    first = preview(pdf).fetch(:session)
    second = preview(workbook).fetch(:session)

    third = preview(remove_roles: [ "supplemental_workbook" ], supersedes_package_id: second.package_id,
      supersession_reason: "Removed: Tips & loans workbook. Wrong period").fetch(:session)

    # The same PDF alone was version 1, which is superseded; this is a new version, not a reopened one.
    expect(third).to have_attributes(supersedes_id: second.id, package_revision: 3, supersession_reason: "Removed: Tips & loans workbook. Wrong period")
    expect(third.id).not_to eq(first.id)
    expect(roles(third)).to eq([ "revel_hours" ])
    expect(third.evidence_snapshot.fetch("source_changes")).to include("removed" => [ "supplemental_workbook" ])
    expect(second.reload).to be_superseded

    fourth = preview(workbook).fetch(:session)
    expect(fourth).to have_attributes(supersedes_id: third.id, package_revision: 4, supersession_reason: "Added: Tips & loans workbook")
    expect(roles(fourth)).to eq(%w[revel_hours supplemental_workbook])
  end

  it "says when a file saved before verification is not kept, instead of dropping it quietly" do
    first = preview(pdf).fetch(:session)
    first.documents.sole.update_columns(verification_status: "legacy_unverified")

    second = preview(workbook).fetch(:session)

    expect(roles(second)).to eq([ "supplemental_workbook" ])
    expect(second.supersession_reason).to eq("Added: Tips & loans workbook. Not kept (saved before files were verified): Revel hours PDF")
    expect(second.warnings).to include(include("code" => "unverified_source_not_kept", "message" => include("Revel hours PDF in import version 1")))
    expect(second.evidence_snapshot.dig("source_changes", "not_kept_unverified")).to eq([ { "role" => "revel_hours", "document_id" => first.documents.sole.id } ])
  end

  it "refuses a carried file whose retained bytes no longer match their fingerprint" do
    first = preview(pdf).fetch(:session)
    objects[first.documents.first.storage_reference] = "tampered"

    expect { preview(workbook) }.to raise_error(PayrollIntake::SourcePackageVerifier::VerificationError)
    expect(first.reload).to be_current
  end
end
