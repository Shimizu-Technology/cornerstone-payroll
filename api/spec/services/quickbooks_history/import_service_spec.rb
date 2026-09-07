# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::ImportService do
  let!(:company) { create(:company) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  before { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }
  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  it "stages immutable history without creating live payroll or YTD records" do
    live_counts = [ PayPeriod.count, PayrollItem.count, EmployeeYtdTotal.count ]
    expect do
      @result = described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call
    end.to change(HistoricalPaycheck, :count).by(2)
      .and change(HistoricalPayPeriod, :count).by(2)
      .and change(HistoricalWorker, :count).by(3)
    expect([ PayPeriod.count, PayrollItem.count, EmployeeYtdTotal.count ]).to eq(live_counts)

    batch = @result.batch
    expect(batch).to be_previewed
    expect(batch.historical_import_source_files.count).to eq(5)
    expect(batch.source_files_complete_and_verified?).to be(true)
    expect(batch.historical_import_source_files.in_manifest_order.map(&:sha256)).to eq(
      batch.source_file_manifest.sort_by { |entry| entry.fetch("position") }.pluck("sha256")
    )
    expect(batch.historical_paychecks.find_by(source_employee_name: "Worker, Alice")).to have_attributes(
      gross_pay: 1_000.to_d,
      net_pay: 725.to_d,
      federal_income_tax: 100.to_d
    )
    worker = batch.historical_workers.find_by(source_name: "Worker, Alice")
    encrypted_value = HistoricalWorker.connection.select_value(
      HistoricalWorker.sanitize_sql_array([ "SELECT private_snapshot FROM historical_workers WHERE id = ?", worker.id ])
    )
    expect(encrypted_value).not_to include("000-00-0001")
    expect(worker.private_snapshot_data.dig("Tax info")).to include("000-00-0001")
    expect(worker.private_snapshot_data.dig("_employee_directory", "Email")).to eq("alice@example.test")
    expect(batch.historical_workers.find_by!(source_name: "Worker, Charlie")).to have_attributes(
      source_status: "active",
      mapping_status: "needs_review"
    )
  end

  it "stores parsed Tax and Wage Summary reports as immutable source evidence" do
    result = described_class.new(
      company: company,
      files: quickbooks_history_uploads + quickbooks_tax_wage_uploads,
      actor: actor
    ).call

    expect(result).to be_success
    expect(result.batch.tax_wage_reconciliation).to include("passed" => true, "report_count" => 5)
    expect(result.batch.historical_tax_wage_reports.count).to eq(5)
    annual = result.batch.historical_tax_wage_reports.find_by!(scope: "annual")
    expect(annual.tax_lines.dig("federal_income_tax", "taxable_wages")).to eq("2950.0")
    expect(annual.update(period_end: Date.new(2024, 12, 30))).to be(false)
  end

  it "retains a blocked duplicate-period preview without violating the report ledger constraint" do
    files = quickbooks_history_uploads + quickbooks_tax_wage_uploads
    files << build_quickbooks_xls(
      "Tax_and_Wage_Summary_2024_duplicate_Q1.xls",
      empty_tax_wage_summary_rows("Jan 01, 2024", "Mar 31, 2024")
    )

    result = described_class.new(company: company, files: files, actor: actor).call

    expect(result).to be_success
    expect(result.batch.validation_errors.join(" ")).to match(/more than one Tax and Wage Summary for Q1/)
    expect(result.batch.historical_tax_wage_reports).to be_empty
    expect(result.batch.historical_import_source_files.count).to eq(files.size)
  end

  it "returns the existing batch when the same bundle is uploaded again" do
    files = quickbooks_history_uploads
    first = described_class.new(company: company, files: files, actor: actor).call
    second = described_class.new(company: company, files: files, actor: actor).call

    expect(second.idempotent).to be(true)
    expect(second.batch).to eq(first.batch)
    expect(HistoricalImportBatch.count).to eq(1)
    expect(HistoricalPaycheck.count).to eq(2)
    expect(HistoricalImportSourceFile.count).to eq(5)
  end

  it "creates a fresh auditable preview when the importer version changes" do
    files = quickbooks_history_uploads + quickbooks_tax_wage_uploads
    first = described_class.new(company: company, files: files, actor: actor).call
    first.batch.update_column(:importer_version, "quickbooks-online-payroll-v4")

    second = described_class.new(company: company, files: files, actor: actor).call

    expect(second).to be_success
    expect(second.idempotent).to be(false)
    expect(second.batch).not_to eq(first.batch)
    expect(second.batch).to have_attributes(
      bundle_digest: first.batch.bundle_digest,
      importer_version: QuickbooksHistory::BundleParser::IMPORTER_VERSION
    )
    expect(second.batch.tax_wage_reconciliation).to include("passed" => true, "report_count" => 5)
    expect(second.batch.historical_tax_wage_reports.count).to eq(5)
    expect(HistoricalImportBatch.count).to eq(2)
  end

  it "fails clearly instead of returning an older importer during the legacy-index rollout" do
    files = quickbooks_history_uploads
    first = described_class.new(company: company, files: files, actor: actor).call
    first.batch.update_column(:importer_version, "quickbooks-online-payroll-v4")
    allow(HistoricalImportBatch).to receive(:create!).and_raise(ActiveRecord::RecordNotUnique)

    result = described_class.new(company: company, files: files, actor: actor).call

    expect(result).not_to be_success
    expect(result.idempotent).to be(false)
    expect(result.error.message).to match(/already imported as quickbooks-online-payroll-v4.*importer-version migration/i)
  end

  it "automatically links only an unambiguous name-and-SSN identity match" do
    employee = create(
      :employee,
      company: company,
      department: create(:department, company: company),
      first_name: "Alice",
      last_name: "Worker",
      ssn_encrypted: "000-00-0001"
    )

    batch = described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
    worker = batch.historical_workers.find_by!(source_name: "Worker, Alice")

    expect(worker).to have_attributes(
      employee_id: employee.id,
      mapping_status: "exact_match",
      match_method: "exact_normalized_name_and_ssn",
      match_confidence: 1
    )
    expect(worker.historical_paychecks.distinct.pluck(:employee_id)).to eq([ employee.id ])
  end

  it "requires review when the name matches but the SSN does not" do
    create(
      :employee,
      company: company,
      department: create(:department, company: company),
      first_name: "Alice",
      last_name: "Worker",
      ssn_encrypted: "999-99-9999"
    )

    batch = described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch

    expect(batch.historical_workers.find_by!(source_name: "Worker, Alice")).to have_attributes(
      employee_id: nil,
      mapping_status: "needs_review",
      match_method: nil,
      match_confidence: nil
    )
  end

  it "requires review when more than one live employee has the same name and SSN" do
    department = create(:department, company: company)
    create_list(
      :employee,
      2,
      company: company,
      department: department,
      first_name: "Alice",
      last_name: "Worker",
      ssn_encrypted: "000-00-0001"
    )

    batch = described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch

    expect(batch.historical_workers.find_by!(source_name: "Worker, Alice")).to have_attributes(
      employee_id: nil,
      mapping_status: "needs_review",
      match_method: nil,
      match_confidence: nil
    )
  end

  it "flags overlapping paychecks from a different bundle" do
    first = described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call
    review_historical_workers_as_archive_only(first.batch, actor: actor)
    QuickbooksHistory::LifecycleService.new(batch: first.batch, actor: actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    cleanup_quickbooks_history_uploads

    second = described_class.new(company: company, files: quickbooks_history_uploads(suffix: "changed"), actor: actor).call

    expect(second.batch.validation_errors).to include("2 paycheck snapshot(s) already exist in applied QuickBooks history")
    expect(second.batch).to be_previewed
  end

  it "checks large external-key sets in bounded database queries" do
    rows = (1..(described_class::EXTERNAL_KEY_QUERY_BATCH_SIZE + 1)).map do |index|
      { external_key: "source-key-#{index}" }
    end
    service = described_class.new(company: company, files: [], actor: actor)
    expect(HistoricalPaycheck).to receive(:joins).twice.and_call_original

    expect(service.send(:duplicate_source_count, rows)).to eq(0)
  end

  it "returns a failure result after rolling back an invalid persistence operation" do
    invalid_batch = HistoricalImportBatch.new
    invalid_batch.errors.add(:source_label, "can't be blank")
    persistence_error = ActiveRecord::RecordInvalid.new(invalid_batch)
    allow(HistoricalPaycheck).to receive(:insert_all!).and_raise(persistence_error)

    result = described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call

    expect(result).not_to be_success
    expect(result.error).to eq(persistence_error)
    expect(result.batch).to be_nil
    expect(HistoricalImportBatch.count).to eq(0)
    expect(HistoricalWorker.count).to eq(0)
    expect(HistoricalPayPeriod.count).to eq(0)
    expect(HistoricalPaycheck.count).to eq(0)
    expect(HistoricalImportSourceFile.count).to eq(0)
    expect(Dir[R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll/**/*")].select { |path| File.file?(path) }).to be_empty
  end

  it "attaches protected source evidence when an older matching preview is uploaded again" do
    files = quickbooks_history_uploads
    first = described_class.new(company: company, files: files, actor: actor).call
    HistoricalImportSourceFile.where(historical_import_batch_id: first.batch.id).delete_all

    second = described_class.new(company: company, files: files, actor: actor).call

    expect(second).to be_success
    expect(second.idempotent).to be(true)
    expect(second.batch).to eq(first.batch)
    expect(second.batch.historical_import_source_files.count).to eq(5)
    expect(second.batch.source_files_complete_and_verified?).to be(true)
  end

  it "returns parser validation failures through the service result contract" do
    details = payroll_details_rows
    details[5][5] = "not money"

    result = described_class.new(
      company: company,
      files: authoritative_quickbooks_files(details: details, history: paycheck_history_rows),
      actor: actor
    ).call

    expect(result).not_to be_success
    expect(result.error).to be_a(ArgumentError)
    expect(result.error.message).to match(/Gross pay - total is not a valid number/)
    expect(HistoricalImportBatch.count).to eq(0)
  end

  it "re-raises an unrelated unique-index violation instead of misreporting an idempotent race" do
    database_error = ActiveRecord::RecordNotUnique.new("different unique index")
    allow(HistoricalPaycheck).to receive(:insert_all!).and_raise(database_error)

    expect do
      described_class.new(company: company, files: quickbooks_history_uploads, actor: actor).call
    end.to raise_error(database_error)
  end
end
