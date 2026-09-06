# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::ReportBuilder do
  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }

  before { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }
  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  it "reports only accepted snapshots and keeps opening summaries separate" do
    batch = imported_batch
    preview_report = described_class.new(company: company, report_type: "register").call
    expect(preview_report.dig(:summary, :paycheck_count)).to eq(0)

    apply_batch(batch)
    report = described_class.new(company: company, report_type: "register").call

    expect(report.dig(:summary, :paycheck_count)).to eq(2)
    expect(report.dig(:summary, :detailed_paycheck_count)).to eq(1)
    expect(report.dig(:summary, :opening_summary_count)).to eq(1)
    expect(report.dig(:summary, :totals, :gross_pay)).to eq(3_000.to_d)
    expect(report.dig(:summary, :detailed_paycheck_totals, :gross_pay)).to eq(1_000.to_d)
    expect(report.dig(:summary, :opening_summary_totals, :gross_pay)).to eq(2_000.to_d)
    expect(report.fetch(:rows).pluck(:record_kind)).to contain_exactly("Detailed paycheck", "Opening summary")
    expect(report.fetch(:warnings).join(" ")).to include("not individual pay periods")
    expect(report.to_json).not_to include("000-00-0001", "private_snapshot", "storage_key")
  end

  it "preserves tax, deduction, loan, retirement, and contribution components exactly" do
    batch = imported_batch
    apply_batch(batch)

    taxes = described_class.new(company: company, report_type: "taxes").call
    deductions = described_class.new(company: company, report_type: "deductions").call

    alice_taxes = taxes.fetch(:rows).select { |row| row.fetch(:employee) == "Worker, Alice" }
    expect(alice_taxes.select { |row| row.fetch(:tax_side) == "Employee" }.sum { |row| row.fetch(:amount) }).to eq(200.to_d)
    expect(alice_taxes.select { |row| row.fetch(:tax_side) == "Employer" }.sum { |row| row.fetch(:amount) }).to eq(100.to_d)

    alice_deductions = deductions.fetch(:rows).select { |row| row.fetch(:employee) == "Worker, Alice" }
    expect(alice_deductions).to include(hash_including(category: "Pre-tax deduction", component: "401(k) Pre-Tax", amount: 50.to_d))
    expect(alice_deductions).to include(hash_including(category: "After-tax deduction", component: "Loan", amount: 25.to_d))
    expect(alice_deductions).to include(hash_including(category: "Employer contribution", component: "401(k) Pre-Tax", amount: 50.to_d))
  end

  it "filters by source year and normalized worker without leaking another company" do
    batch = imported_batch
    apply_batch(batch)
    other_company = create(:company, historical_payroll_enabled: true)
    other_actor = create(:user, company: other_company, organization: other_company.organization, role: "admin")
    cleanup_quickbooks_history_uploads
    other_batch = QuickbooksHistory::ImportService.new(
      company: other_company,
      files: quickbooks_history_uploads(suffix: "other"),
      actor: other_actor
    ).call.batch
    review_historical_workers_as_archive_only(other_batch, actor: other_actor)
    QuickbooksHistory::LifecycleService.new(batch: other_batch, actor: other_actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )

    report = described_class.new(
      company: company,
      report_type: "employee_summary",
      year: 2024,
      worker_key: QuickbooksHistory::NameNormalizer.call("Worker, Alice")
    ).call

    expect(report.fetch(:rows).sole).to include(employee: "Worker, Alice", gross_pay: 1_000.to_d)
    expect(report.fetch(:available_years)).to eq([ 2024 ])
    expect(report.fetch(:provenance).pluck(:batch_id)).to eq([ batch.id ])
  end

  it "builds provenance-first XLSX/PDF sheets and stable filenames" do
    batch = imported_batch
    apply_batch(batch)
    builder = described_class.new(company: company, report_type: "checks", year: 2024)
    report = builder.call
    sheets = builder.sheets(report)

    expect(sheets.pluck(:name)).to eq([ "Report information", "Historical Check & Payment History", "Source batches" ])
    expect(sheets.first.fetch(:rows)).to include([ "Source", report.fetch(:source_statement) ])
    expect(sheets.last.fetch(:rows).flatten).to include(batch.bundle_digest)
    expect(builder.filename(:xlsx)).to eq("historical_checks_company_#{company.id}_2024_all-workers.xlsx")
  end

  it "rejects unknown reports and invalid years" do
    expect do
      described_class.new(company: company, report_type: "made_up")
    end.to raise_error(ArgumentError, "Unknown historical report")
    expect do
      described_class.new(company: company, report_type: "register", year: "last year")
    end.to raise_error(ArgumentError, /year must be between/)
  end

  private

  def imported_batch
    QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
  end

  def apply_batch(batch)
    review_historical_workers_as_archive_only(batch, actor: actor)
    QuickbooksHistory::LifecycleService.new(batch: batch, actor: actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
  end
end
