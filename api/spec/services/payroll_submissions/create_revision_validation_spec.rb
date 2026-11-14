# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollSubmissions::CreateRevision do
  let(:company) { create(:company, payroll_intake_source_types: [ "mosa_revel" ]) }
  let(:client) { create(:user, company: company, role: "client") }
  let!(:run) { create(:pay_period, company: company, start_date: Date.new(2026, 10, 19), end_date: Date.new(2026, 11, 1), pay_date: Date.new(2026, 11, 5)) }
  let(:catalog) { PayrollSubmissions::Catalog.new(company: company, today: Date.new(2026, 11, 14)) }

  def send_revision(**params)
    described_class.new(company: company, actor: client, catalog: catalog,
      entry: catalog.resolve("2026-10-19_2026-11-01"), params: params).call
  end

  it "requires a structured change or no-changes answer even with a workbook" do
    expect do
      send_revision(revel_payroll: synthetic_pdf, workbook_choice: "attach", changes_workbook: synthetic_workbook)
    end.to raise_error(PayrollSubmissions::FileSet::Invalid) { |error| expect(error.details).to have_key("changes") }
    expect(PayrollSubmission.count).to eq(0)
  end

  [ nil, false, "false" ].each do |supporting|
    it "refuses new Excel with a kept workbook when supporting is #{supporting.inspect}" do
      first = send_revision(revel_payroll: synthetic_pdf, workbook_choice: "attach", changes_workbook: synthetic_workbook, no_changes: true).submission
      expect do
        send_revision(workbook_choice: "attach", no_changes: true, based_on_revision: 1,
          keep_document_ids: first.submission_documents.pluck(:client_document_id),
          attachments: [ synthetic_workbook("corrected.xlsx") ], excel_attachments_supporting: supporting)
      end.to raise_error(PayrollSubmissions::FileSet::Invalid) { |error| expect(error.details).to have_key("attachment") }
      expect(first.period.submissions.count).to eq(1)
    end
  end

  it "keeps explicitly confirmed supporting Excel separate from the imported workbook" do
    first = send_revision(revel_payroll: synthetic_pdf, workbook_choice: "attach", changes_workbook: synthetic_workbook, no_changes: true).submission
    result = send_revision(workbook_choice: "attach", no_changes: true, based_on_revision: 1,
      keep_document_ids: first.submission_documents.pluck(:client_document_id),
      attachments: [ synthetic_workbook("support.xlsx") ], excel_attachments_supporting: "true")
    expect(result.submission.revision).to eq(2)
    expect(result.submission.submission_documents.find_by!(role: "changes_workbook").client_document_id).to eq(first.submission_documents.find_by!(role: "changes_workbook").client_document_id)
    expect(result.submission.submission_documents.find_by!(role: "attachment").file_name_snapshot).to eq("support.xlsx")
  end
end
