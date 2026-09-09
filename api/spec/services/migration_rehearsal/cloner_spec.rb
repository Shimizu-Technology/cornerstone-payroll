# frozen_string_literal: true

require "rails_helper"

RSpec.describe MigrationRehearsal::Cloner do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization, client_limit: 1) }
  let(:source_company) do
    create(
      :company,
      organization: organization,
      name: "Example Payroll",
      ein: "12-3456789",
      historical_payroll_enabled: true
    )
  end
  let(:actor) { create(:user, company: source_company, organization: organization, role: "admin") }
  let(:employee) do
    create(
      :employee,
      company: source_company,
      department: nil,
      first_name: "Sample",
      last_name: "Employee",
      pay_rate: 18.75,
      configuration_source: "quickbooks_history",
      configuration_review_status: "needs_review",
      configuration_review_items: [
        { "code" => "verify_setup", "message" => "Confirm imported setup", "fields" => [ "hire_date" ] }
      ]
    )
  end
  let(:source_bytes) { "synthetic QuickBooks source" }
  let(:source_key) { "historical-payroll/company-#{source_company.id}/rehearsal-spec/source-00.xlsx" }
  let(:storage) { R2StorageService.new }
  let(:batch) do
    create(
      :historical_import_batch,
      company: source_company,
      status: "locked",
      created_by: actor,
      applied_by: actor,
      locked_by: actor,
      applied_at: 1.day.ago,
      locked_at: Time.current,
      source_file_manifest: [
        {
          "position" => 0,
          "filename" => "Payroll Details.xlsx",
          "byte_size" => source_bytes.bytesize,
          "sha256" => Digest::SHA256.hexdigest(source_bytes),
          "report_type" => "payroll_details"
        }
      ]
    )
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    storage.upload(source_key, source_bytes, content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
    @source_file = HistoricalImportSourceFile.create!(
      historical_import_batch: batch,
      company: source_company,
      uploaded_by: actor,
      original_filename: "Payroll Details.xlsx",
      content_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      byte_size: source_bytes.bytesize,
      sha256: Digest::SHA256.hexdigest(source_bytes),
      storage_key: source_key,
      report_type: "payroll_details",
      position: 0,
      verification_status: "verified",
      verified_at: Time.current
    )
    worker = create(
      :historical_worker,
      historical_import_batch: batch,
      company: source_company,
      employee: employee,
      mapping_status: "exact_match",
      private_snapshot: JSON.generate("hire_date" => "2024-01-01")
    )
    period = HistoricalPayPeriod.create!(
      historical_import_batch: batch,
      company: source_company,
      external_key: "2026-08-01:2026-08-14:2026-08-21",
      source_label: "08/01/2026 - 08/14/2026",
      start_date: Date.new(2026, 8, 1),
      end_date: Date.new(2026, 8, 14),
      pay_date: Date.new(2026, 8, 21),
      paycheck_count: 1,
      totals: { "gross_pay" => "1500.00", "net_pay" => "1200.00" }
    )
    HistoricalPaycheck.create!(
      historical_import_batch: batch,
      historical_pay_period: period,
      historical_worker: worker,
      company: source_company,
      employee: employee,
      external_key: "paycheck-1",
      source_employee_name: "Employee, Sample",
      pay_date: period.pay_date,
      period_start: period.start_date,
      period_end: period.end_date,
      source_row_number: 2,
      reconciliation_status: "matched",
      gross_pay: 1_500,
      employee_taxes: 200,
      after_tax_deductions: 100,
      net_pay: 1_200,
      employer_taxes: 115,
      total_payroll_cost: 1_615
    )
    CompanyAssignment.create!(user: actor, company: source_company)
  end

  after do
    storage.delete(source_key)
    storage.list(prefix: "historical-payroll/company-").grep(%r{/migration-rehearsal/batch-#{batch.id}/}).each do |key|
      storage.delete(key)
    end
    clear_enqueued_jobs
  end

  it "previews and queues one protected-data rehearsal without consuming a live client seat" do
    preview = MigrationRehearsal::Preview.new(source_company: source_company, batch: batch).call

    expect(preview).to include(ready: true)
    expect(preview.dig(:copy_summary, :imported_paychecks)).to eq(1)

    expect {
      @target = MigrationRehearsal::Create.new(
        source_company: source_company,
        actor: actor,
        acknowledgement: MigrationRehearsal::Create::ACKNOWLEDGEMENT,
        batch: batch
      ).call
    }.to have_enqueued_job(MigrationRehearsal::CloneJob)

    expect(@target).to have_attributes(
      payroll_environment: "migration_rehearsal",
      migration_rehearsal_status: "pending",
      migration_source_company_id: source_company.id,
      ein: source_company.ein
    )
    expect(organization.reload.companies.live_payroll.count).to eq(1)
  end

  it "copies setup and the immutable archive, re-verifies source bytes, and leaves the source unchanged" do
    HistoricalTaxWageReport.create!(
      company: source_company,
      historical_import_batch: batch,
      historical_import_source_file: @source_file,
      scope: "year_to_date",
      source_position: 0,
      period_start: Date.new(2026, 1, 1),
      period_end: Date.new(2026, 8, 21),
      report_digest: Digest::SHA256.hexdigest("tax-wage-report"),
      tax_lines: { "federal_income_tax" => "200.00" }
    )
    bootstrap = HistoricalClientBootstrap.create!(
      company: source_company,
      historical_import_batch: batch,
      created_by: actor,
      applied_by: actor,
      plan_digest: Digest::SHA256.hexdigest("bootstrap"),
      status: "applied",
      applied_at: Time.current
    )
    bridge = HistoricalYtdBridge.create!(
      company: source_company,
      historical_import_batch: batch,
      historical_client_bootstrap: bootstrap,
      created_by: actor,
      applied_by: actor,
      plan_digest: Digest::SHA256.hexdigest("bridge"),
      status: "applied",
      revision: 1,
      applied_at: Time.current,
      apply_acknowledgement: "APPLY HISTORICAL YTD",
      preview_summary: { "through_period_end" => "2026-08-14", "through_pay_date" => "2026-08-21" }
    )
    HistoricalEmployeeYtdBalance.create!(
      historical_ytd_bridge: bridge,
      company: source_company,
      employee: employee,
      tax_year: 2026,
      through_period_end: Date.new(2026, 8, 14),
      through_pay_date: Date.new(2026, 8, 21),
      gross_pay: 1_500,
      net_pay: 1_200
    )
    target = Company.create!(
      source_company.attributes.slice(*MigrationRehearsal::Create::COMPANY_FIELDS).merge(
        name: "Example Payroll Migration Test",
        organization: organization,
        payroll_environment: "migration_rehearsal",
        migration_source_company: source_company,
        migration_source_batch: batch,
        migration_rehearsal_status: "pending",
        migration_rehearsal_created_by: actor,
        migration_rehearsal_created_at: Time.current,
        auto_create_fit_check: false,
        payroll_intake_source_types: []
      )
    )

    described_class.new(company: target, source_batch: batch, actor: actor, storage: storage).call

    target.reload
    copied_batch = target.historical_import_batches.where(status: "locked").sole
    copied_employee = target.employees.sole
    expect(target.migration_rehearsal_status).to eq("ready")
    expect(copied_employee).to have_attributes(first_name: "Sample", pay_rate: 18.75.to_d)
    expect(copied_employee.configuration_review_items).to eq([
      { "code" => "verify_setup", "message" => "Confirm imported setup", "fields" => [ "hire_date" ] }
    ])
    expect(copied_batch.historical_paychecks.sole).to have_attributes(gross_pay: 1_500.to_d, net_pay: 1_200.to_d)
    expect(copied_batch.historical_paychecks.sole.employee).to eq(copied_employee)
    expect(copied_batch.historical_tax_wage_reports.sole.historical_import_source_file).to eq(
      copied_batch.historical_import_source_files.sole
    )
    expect(copied_batch.historical_ytd_bridges.sole.historical_employee_ytd_balances.sole).to have_attributes(
      employee: copied_employee,
      gross_pay: 1_500.to_d
    )
    expect(copied_batch.historical_import_source_files.sole.storage_key).not_to eq(source_key)
    expect(storage.download(copied_batch.historical_import_source_files.sole.storage_key)).to eq(source_bytes)
    expect(batch.reload.historical_paychecks.sole.gross_pay).to eq(1_500.to_d)
    expect(CompanyAssignment.exists?(user: actor, company: target)).to be(true)
  end

  it "forces every rehearsal pay period into non-committable parallel mode" do
    target = Company.create!(
      organization: organization,
      name: "Example Payroll Migration Test",
      payroll_environment: "migration_rehearsal",
      migration_source_company: source_company,
      migration_source_batch: batch,
      migration_rehearsal_status: "ready"
    )
    period = PayPeriod.create!(
      company: target,
      start_date: Date.new(2026, 8, 15),
      end_date: Date.new(2026, 8, 28),
      pay_date: Date.new(2026, 9, 4),
      status: "draft"
    )

    expect(period).to be_parallel_run
    expect(period.update(status: "committed")).to be(false)
    expect(period.errors.full_messages.join).to include("cannot be committed")
  end

  it "retries a failed copy against the exact source batch" do
    target = Company.create!(
      organization: organization,
      name: "Example Payroll Migration Test",
      payroll_environment: "migration_rehearsal",
      migration_source_company: source_company,
      migration_source_batch: batch,
      migration_rehearsal_status: "failed",
      migration_rehearsal_error: "Temporary storage failure"
    )

    expect {
      MigrationRehearsal::Retry.new(company: target, actor: actor).call
    }.to have_enqueued_job(MigrationRehearsal::CloneJob).with(target.id, batch.id, actor.id)

    expect(target.reload).to have_attributes(migration_rehearsal_status: "pending", migration_rehearsal_error: nil)
  end

  it "records a safe retryable failure after rolling back an incomplete copy" do
    target = Company.create!(
      organization: organization,
      name: "Example Payroll Migration Test",
      payroll_environment: "migration_rehearsal",
      migration_source_company: source_company,
      migration_source_batch: batch,
      migration_rehearsal_status: "pending"
    )
    failed_storage = instance_double(R2StorageService)
    allow(failed_storage).to receive(:list).and_return([])
    allow(failed_storage).to receive(:download_with_limit).and_return("tampered source")

    expect {
      described_class.new(company: target, source_batch: batch, actor: actor, storage: failed_storage).call
    }.to raise_error(RuntimeError, /integrity verification/)

    expect(target.reload).to have_attributes(
      migration_rehearsal_status: "failed",
      migration_rehearsal_error: "The rehearsal copy did not finish. No source data changed. Retry the verified copy."
    )
    expect(target.employees).to be_empty
    expect(target.historical_import_batches).to be_empty
  end

  it "does not clean completed files when a duplicate job arrives late" do
    target = Company.create!(
      organization: organization,
      name: "Example Payroll Migration Test",
      payroll_environment: "migration_rehearsal",
      migration_source_company: source_company,
      migration_source_batch: batch,
      migration_rehearsal_status: "ready"
    )
    untouched_storage = instance_double(R2StorageService)
    expect(untouched_storage).not_to receive(:list)
    expect(untouched_storage).not_to receive(:delete)

    expect {
      described_class.new(company: target, source_batch: batch, actor: actor, storage: untouched_storage).call
    }.to raise_error(ArgumentError, /already been prepared/)

    expect(target.reload.migration_rehearsal_status).to eq("ready")
  end
end
