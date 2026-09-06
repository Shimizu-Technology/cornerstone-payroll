# frozen_string_literal: true

require "rails_helper"

RSpec.describe HistoricalImportSourceFile, type: :model do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  after { cleanup_quickbooks_history_uploads }

  it "keeps original evidence metadata immutable and prevents deletion" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
    source_file = batch.historical_import_source_files.first

    expect(source_file.update(original_filename: "replacement.xls")).to be(false)
    expect(source_file.errors.full_messages).to include("Historical source-file evidence cannot be changed")
    expect(source_file.destroy).to be(false)
    expect(source_file.errors.full_messages).to include("Historical source files cannot be deleted")
  end

  it "allows integrity status to record a later verification failure" do
    batch = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
    source_file = batch.historical_import_source_files.first

    expect(source_file.update(verification_status: "failed", verification_error: "Stored file is unavailable")).to be(true)
    expect(source_file.reload).to have_attributes(
      verification_status: "failed",
      verification_error: "Stored file is unavailable"
    )
  end
end
