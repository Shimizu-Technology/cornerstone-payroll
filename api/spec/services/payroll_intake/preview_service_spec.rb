# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollIntake::PreviewService do
  let!(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let!(:run) { create(:pay_period, company: company) }
  let!(:actor) { create(:user, company: company, role: "admin") }
  let!(:employee) { create(:employee, company: company, first_name: "Avery", last_name: "Example") }
  let!(:period) { PayrollSubmissionPeriod.create!(company: company, pay_period: run, source: "pay_period", start_date: run.start_date, end_date: run.end_date) }
  let(:bytes) { File.binread(build_revel_pdf([ { name: "Example, Avery", regular_hours: 40, regular_pay: 400 } ], period_start: run.start_date, period_end: run.end_date)) }
  let(:storage) do
    objects = {}
    Object.new.tap do |store|
      store.define_singleton_method(:upload) { |key, data, **| objects[key] = data }
      store.define_singleton_method(:download_with_limit) { |key, **| objects.fetch(key) }
      store.define_singleton_method(:delete) { |key| objects.delete(key) }
    end
  end

  before do
    CompanyWorkweek.create!(company: company, starts_on_weekday: run.start_date.wday, starts_at_minutes: 0,
      timezone: "Pacific/Guam", effective_on: run.start_date, source: "operator_confirmed", confirmation_status: "confirmed",
      confirmed_by: actor, confirmed_at: Time.current, notes: "Synthetic workweek")
  end

  def submission(revision, amount = "100")
    period.submissions.create!(company: company, revision: revision, submitted_at: Time.current,
      content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32),
      change_rows: [ { kind: "owner_pay", employee_id: employee.id, amount: amount } ])
  end

  def preview(source = nil, **options)
    described_class.new(pay_period: run, source_type: "mosa_revel", actor: actor, storage: storage,
      portal_submission: source, files: [ portal_upload("revel.pdf", bytes, "application/pdf") ], **options).call
  end

  def applied(source)
    package = preview(source).fetch(:session)
    record = PayrollImportRecord.create!(pay_period: run, payroll_intake_session: package, status: "applied")
    PayrollSubmissionImport.create!(payroll_submission: source, current_submission: source, payroll_import: record,
      selected_by: actor, applied_at: Time.current)
    package.mark_applied!(actor: actor)
    package
  end

  it "retains identical sources as a new auditable package for edited changes, deduplicates retry, and protects plain imports" do
    original = submission(1)
    first = applied(original)
    corrected = submission(2, "200")
    result = preview(corrected)
    second = result.fetch(:session)
    expect(result[:duplicate]).to be(false)
    expect(second).to have_attributes(supersedes_id: first.id, supersession_reason: "client revision 2: changes only")
    expect(second.evidence_snapshot).to include("source_import_hash" => first.evidence_snapshot.fetch("source_import_hash"),
      "payroll_submission_id" => corrected.id)
    expect(second.documents.pluck(:sha256)).to eq(first.documents.pluck(:sha256))
    expect(first.reload).not_to be_applyable
    expect(second).to be_applyable
    expect(preview(corrected)).to include(duplicate: true, session: second)
    expect(preview).to include(duplicate: true, session: first)
    expect { preview(original) }.to raise_error(ArgumentError, /revision was already applied/)
    expect(PayrollIntakeSession.count).to eq(2)
  end

  it "keeps a changes-only correction after a status change alters the active roster" do
    original = submission(1)
    first = applied(original)
    other = create(:employee, company: company, first_name: "Blake", last_name: "Other", status: "inactive")
    EmployeeStatusTransitionService.reactivate!(employee: other, actor: actor, attributes: { effective_date: run.start_date.iso8601 })
    corrected = submission(2, "200")
    second = preview(corrected).fetch(:session)

    expect(second).to have_attributes(supersedes_id: first.id, supersession_reason: "client revision 2: changes only")
    expect(second.evidence_snapshot).to include("source_import_hash" => first.evidence_snapshot.fetch("source_import_hash"),
      "payroll_submission_id" => corrected.id)
    expect(preview(corrected)).to include(duplicate: true, session: second)
  end

  it "recognizes the same files in a package stored before the roster joined the import key" do
    original = submission(1)
    first = applied(original)
    file_only_hash = first.evidence_snapshot.fetch("source_import_hash")
    first.update_columns(import_hash: file_only_hash, evidence_snapshot: first.evidence_snapshot.except("source_import_hash"))
    second = preview(submission(2, "200")).fetch(:session)

    expect(second).to have_attributes(supersedes_id: first.id, supersession_reason: "client revision 2: changes only")
    expect(second.evidence_snapshot).to include("source_import_hash" => file_only_hash)
  end

  it "refuses an identical re-send and preserves the applied current package" do
    original = submission(1)
    first = applied(original)
    corrected = submission(2)
    expect { preview(corrected) }.to raise_error(ArgumentError, /repeats the already-applied files and changes/)
    expect(first.reload).to be_current
    expect(PayrollIntakeSession.count).to eq(1)
  end

  it "keeps explicit stale predecessor checks for an identical-files correction" do
    original = submission(1)
    first = applied(original)
    corrected = submission(2, "200")
    expect { preview(corrected, supersedes_package_id: "stale-package") }.to raise_error(described_class::ReplacementRequiredError)
    expect(first.reload).to be_current
    expect(PayrollIntakeSession.count).to eq(1)
  end

  it "rejects a foreign revision before creating or superseding any package" do
    foreign = submission(1)
    other = create(:pay_period, company: company, start_date: run.start_date + 14, end_date: run.end_date + 14, pay_date: run.pay_date + 14)
    expect do
      described_class.new(pay_period: other, source_type: "mosa_revel", portal_submission: foreign,
        files: [ portal_upload("revel.pdf", bytes, "application/pdf") ]).call
    end.to raise_error(ArgumentError, /same company and period/)
    expect(PayrollIntakeSession.count).to eq(0)
  end
end
