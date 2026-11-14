# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Pay-period submission tenancy and immutability" do
  let(:company) { create(:company) }
  let(:other) { create(:company, organization: company.organization) }
  let(:client) { create(:user, company: company, role: "client") }
  let(:period) { PayrollSubmissionPeriod.create!(company: company, start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 15), source: "schedule") }
  let(:submission) do
    period.submissions.create!(company: company, revision: 1, submitted_by: client, submitted_at: Time.current,
      content_fingerprint: "c", request_fingerprint: "r")
  end

  it "rejects cross-company links in the model and in the database" do
    foreign_document = create(:client_document, company: other)
    link = submission.submission_documents.build(company: company, client_document: foreign_document, role: "revel_payroll",
      sha256: "a" * 64, file_name_snapshot: "x.pdf", file_size_snapshot: 1)
    expect(link).not_to be_valid
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        PayrollSubmissionDocument.insert_all!([ { company_id: company.id, payroll_submission_id: submission.id, client_document_id: foreign_document.id,
        role: "revel_payroll", position: 0, sha256: "a" * 64, file_name_snapshot: "x.pdf", file_size_snapshot: 1,
        created_at: Time.current, updated_at: Time.current } ])
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    foreign_pay_period = create(:pay_period, company: other)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) { period.update_columns(pay_period_id: foreign_pay_period.id) }
    end.to raise_error(ActiveRecord::InvalidForeignKey)
    foreign_thread = create(:client_portal_thread, company: other, created_by: client)
    expect(period.tap { |p| p.client_portal_thread = foreign_thread }).not_to be_valid
  end

  it "allows one Revel PDF per revision and keeps revisions and history immutable" do
    document = create(:client_document, company: company)
    second = create(:client_document, company: company)
    submission.submission_documents.create!(company: company, client_document: document, role: "revel_payroll", sha256: "a" * 64, file_name_snapshot: "a.pdf", file_size_snapshot: 1)
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        submission.submission_documents.create!(company: company, client_document: second, role: "revel_payroll", sha256: "b" * 64, file_name_snapshot: "b.pdf", file_size_snapshot: 1)
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(submission.update(notes: "edited")).to be(false)
    submission.reload
    expect(submission.update(acknowledged_at: Time.current)).to be(true)
    event = period.with_lock { period.transition!("submit", actor: client, submission: submission) }
    expect { event.update!(note: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(document.reload.retained_evidence?).to be(true)
  end

  it "refuses duplicate revision numbers in the database" do
    submission
    expect do
      ActiveRecord::Base.transaction(requires_new: true) do
        period.submissions.create!(company: company, revision: 1, submitted_at: Time.current, content_fingerprint: "c", request_fingerprint: "x")
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
  end
end

RSpec.describe PayrollSubmissionImport do
  it "rejects incomplete staff evidence and cross-company or cross-period selections" do
    company = create(:company)
    run = create(:pay_period, company: company)
    period = PayrollSubmissionPeriod.create!(company: company, pay_period: run, start_date: run.start_date, end_date: run.end_date, source: "pay_period")
    source = period.submissions.create!(company: company, revision: 1, submitted_at: Time.current, content_fingerprint: "c", request_fingerprint: "r")
    actor = create(:user, company: company)
    record = PayrollImportRecord.create!(pay_period: run, status: "previewed")
    selection = described_class.new(payroll_submission: source, current_submission: source, selected_by: actor, payroll_import: record)
    expect(selection).to be_valid
    selection.staff_workbook_attached_by = actor
    selection.staff_workbook_attached_at = Time.current
    expect(selection).not_to be_valid
    expect(selection.errors[:staff_workbook_document]).to be_present
    selection.staff_workbook_attached_by = nil
    selection.staff_workbook_attached_at = nil
    record.update!(pay_period: create(:pay_period, company: create(:company)))
    expect(selection).not_to be_valid
    expect(selection.errors[:base].join).to include("same company and period")
  end
end
