# frozen_string_literal: true

require "rails_helper"

RSpec.describe QuickbooksHistory::CutoverVerificationService do
  before { FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll")) }

  let!(:company) { create(:company, historical_payroll_enabled: true) }
  let!(:actor) { create(:user, company: company, organization: company.organization, role: "admin") }
  let!(:batch) do
    imported = QuickbooksHistory::ImportService.new(company: company, files: quickbooks_history_uploads, actor: actor).call.batch
    review_historical_workers_as_archive_only(imported, actor: actor)
    QuickbooksHistory::LifecycleService.new(batch: imported, actor: actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )
    imported
  end

  after do
    cleanup_quickbooks_history_uploads
    FileUtils.rm_rf(R2StorageService::LOCAL_STORAGE_ROOT.join("historical-payroll"))
  end

  it "re-parses retained originals and proves staged counts, totals, years, and worker review" do
    result = described_class.new(batch: batch, actor: actor).call
    review = result.review

    expect(result.passed).to be(true), review.evidence.fetch("checks").reject { |check| check.fetch("passed") }.inspect
    expect(review.status).to eq("verified")
    expect(review.evidence.fetch("checks")).to all(include("passed" => true))
    expect(review.evidence.fetch("counts")).to eq(
      "worker_count" => 3,
      "period_count" => 2,
      "paycheck_count" => 2
    )
    expect(review.evidence.fetch("years").sole).to include(
      "year" => "2024",
      "paycheck_count" => 2,
      "detailed_paycheck_count" => 1,
      "opening_summary_count" => 1
    )
    expect(review.evidence.fetch("ledger_digests").values).to all(satisfy { |digests| digests.fetch("source") == digests.fetch("stored") })
    expect(review.evidence_digest).to match(/\A[0-9a-f]{64}\z/)
    expect(review.to_json).not_to include("000-00-0001", "private_snapshot", "storage_key")
    expect(AuditLog.where(action: "historical_imports#verify_cutover", record_id: review.id)).to exist
  end

  it "detects record substitutions even when every count and money total still matches" do
    batch.historical_workers.first.update_column(:source_name, "Altered Worker")
    batch.historical_pay_periods.first.update_column(:source_label, "Altered period")
    batch.historical_paychecks.first.update_column(:payment_method, "Altered method")

    result = described_class.new(batch: batch, actor: actor).call
    checks = result.review.evidence.fetch("checks")

    expect(result.passed).to be(false)
    expect(checks).to include(
      include("key" => "stored_totals", "passed" => true),
      include("key" => "year_totals", "passed" => true),
      include("key" => "worker_ledger", "passed" => false),
      include("key" => "period_ledger", "passed" => false),
      include("key" => "paycheck_ledger", "passed" => false)
    )
  end

  it "fails closed when the accepted ledger no longer matches the retained source" do
    batch.historical_paychecks.first.update_column(:net_pay, 1)

    result = described_class.new(batch: batch, actor: actor).call

    expect(result.passed).to be(false)
    expect(result.review.status).to eq("failed")
    expect(result.review.evidence.fetch("checks")).to include(
      include("key" => "stored_totals", "passed" => false),
      include("key" => "year_totals", "passed" => false)
    )
  end

  it "requires an attributed manager or administrator" do
    accountant = create(:user, company: company, organization: company.organization, role: "accountant")

    expect { described_class.new(batch: batch, actor: accountant).call }
      .to raise_error(ArgumentError, /manager or administrator/)
  end
end
