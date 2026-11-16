# frozen_string_literal: true

require "rails_helper"
require "caxlsx"

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
      portal_submission: source, files: source_files, **options).call
  end

  def source_files
    files = [ portal_upload("revel.pdf", bytes, "application/pdf") ]
    files << portal_upload("tips-loans.xlsx", @workbook, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") if @workbook
    files
  end

  # MoSa's own workbook with Avery's $300 installment loan, $25 a payroll.
  def use_installment_workbook!
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: PayrollImport::LoanTipExcelParser::INSTALLMENT_SHEET) do |sheet|
      sheet.add_row([ "INSTALLMENT LOANS" ])
      sheet.add_row([ "PAY PERIOD ENDING", nil, run.end_date ])
      sheet.add_row([ "PAY DAY", nil, run.pay_date ])
      sheet.add_row([ nil, "Nickname", "Last Name", "First Name", "Dept", "Beginning Balance", "New Loan", "Payment", "Estimated Ending" ])
      sheet.add_row([ 1, nil, "Example", "Avery", "Joint", 0, 300, 25, 275 ])
    end
    @workbook = package.to_stream.read
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

  it "deduplicates a plain retry against a package stored before the roster joined the import key" do
    first = preview.fetch(:session)
    first.update_columns(import_hash: first.evidence_snapshot.fetch("source_import_hash"),
      evidence_snapshot: first.evidence_snapshot.except("source_import_hash"))

    expect(preview).to include(duplicate: true, session: first)

    other = create(:employee, company: company, first_name: "Blake", last_name: "Other", status: "inactive")
    EmployeeStatusTransitionService.reactivate!(employee: other, actor: actor, attributes: { effective_date: run.start_date.iso8601 })
    expect { preview }.to raise_error(described_class::ReplacementRequiredError)
    expect(PayrollIntakeSession.count).to eq(1)
  end

  def installment_loan!
    EmployeeLoan.create!(company: company, employee: employee, name: "Advance", original_amount: 300, opening_balance: 300,
      current_balance: 300, balance_as_of: run.pay_date, balance_source: "new_loan", payment_amount: 25, first_deduction_date: run.pay_date)
  end

  def roster_only_hash(source = nil)
    service = described_class.new(pay_period: run, source_type: "mosa_revel", actor: actor, storage: storage,
      portal_submission: source, files: source_files)
    service.send(:snapshot_files!)
    service.send(:roster_import_hash)
  end

  it "makes the same files a new review after a loan is set up, because the review reconciles each worker's loans" do
    use_installment_workbook!
    first = preview.fetch(:session)
    expect(preview).to include(duplicate: true, session: first)

    installment_loan!
    second = preview(carry_forward: true)
    expect(second[:duplicate]).to be(false)
    expect(second[:session]).to have_attributes(supersedes_id: first.id)
    expect(preview(carry_forward: true)).to include(duplicate: true, session: second[:session])
  end

  it "deduplicates a plain retry against a package keyed before loans joined the import key, until a loan changes" do
    use_installment_workbook!
    first = preview.fetch(:session)
    first.update_columns(import_hash: roster_only_hash, created_at: 1.minute.ago)

    expect(preview).to include(duplicate: true, session: first)
    installment_loan!
    expect { preview }.to raise_error(described_class::ReplacementRequiredError)
    expect(PayrollIntakeSession.count).to eq(1)
  end

  it "does not reopen a superseded package keyed before loans joined the import key" do
    first = preview.fetch(:session)
    first.update_columns(import_hash: roster_only_hash, created_at: 1.minute.ago, superseded_at: Time.current)

    expect(preview).not_to include(session: first)
  end

  it "ignores loan activity of a worker the files don't name" do
    use_installment_workbook!
    other = create(:employee, company: company, first_name: "Blake", last_name: "Other")
    first = preview.fetch(:session)
    EmployeeLoan.create!(company: company, employee: other, name: "Advance", original_amount: 300, opening_balance: 300,
      current_balance: 300, balance_as_of: run.pay_date, balance_source: "new_loan", payment_amount: 25, first_deduction_date: run.pay_date)

    expect(preview).to include(duplicate: true, session: first)
  end

  it "finds a changes-only client revision keyed before loans joined the import key" do
    applied(submission(1))
    corrected = submission(2, "200")
    second = preview(corrected).fetch(:session)
    second.update_columns(import_hash: Digest::SHA256.hexdigest("#{roster_only_hash(corrected)}\nclient-revision:#{corrected.id}"), created_at: 1.minute.ago)

    expect(preview(corrected)).to include(duplicate: true, session: second)
  end

  it "requires a replacement for a pre-deploy package once a new active worker is added" do
    first = preview.fetch(:session)
    first.update_columns(import_hash: first.evidence_snapshot.fetch("source_import_hash"),
      evidence_snapshot: first.evidence_snapshot.except("source_import_hash"), created_at: 1.minute.ago)
    create(:employee, company: company, first_name: "Blake", last_name: "Other")

    expect { preview }.to raise_error(described_class::ReplacementRequiredError)
    expect(PayrollIntakeSession.count).to eq(1)
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
