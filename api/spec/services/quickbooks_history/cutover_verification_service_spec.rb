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

  it "retains reviewed decisions for unchanged source exceptions when verification is repeated" do
    review = described_class.new(batch: batch, actor: actor).call.review
    exception_key = review.evidence.fetch("exceptions").sole.fetch("key")
    review.update!(
      exception_dispositions: {
        exception_key => "Accepted after reviewing the reconciled opening summary.",
        "removed-exception" => "This decision must not survive fresh evidence."
      },
      attestations: HistoricalImportCutoverReview::ATTESTATIONS.keys.index_with(true),
      approval_notes: "Ready before re-verification."
    )

    pending = QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call.review
    expect(pending.exception_dispositions).to include(exception_key => "Accepted after reviewing the reconciled opening summary.")
    expect(pending.attestations).to eq({})
    expect(pending.approval_notes).to be_nil

    repeated = described_class.new(
      batch: batch,
      actor: actor,
      expected_verification_started_at: pending.verification_started_at.iso8601(6)
    ).call.review
    expect(repeated.exception_dispositions).to eq(
      exception_key => "Accepted after reviewing the reconciled opening summary."
    )
  end

  it "fails closed when the accepted ledger no longer matches the retained source" do
    batch.historical_paychecks.first.update_column(:net_pay, 1)

    result = described_class.new(batch: batch, actor: actor).call

    expect(result.passed).to be(false)
    expect(result.review.status).to eq("failed")
    expect(result.review.verified_at).to be_nil
    expect(result.review.verified_by).to be_nil
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

  it "requires the attributed operator to retain payroll access" do
    actor.update!(active: false)

    expect { described_class.new(batch: batch, actor: actor).call }
      .to raise_error(ArgumentError, /manager or administrator/)
  end

  it "verifies a batch genuinely recorded by the unchanged v2 parser contract" do
    v2_company = create(:company, organization: company.organization, historical_payroll_enabled: true)
    v2_actor = create(:user, company: v2_company, organization: company.organization, role: "admin")
    v2_batch = nil
    RSpec::Mocks.with_temporary_scope do
      stub_const("QuickbooksHistory::BundleParser::IMPORTER_VERSION", "quickbooks-online-payroll-v2")
      v2_batch = QuickbooksHistory::ImportService.new(
        company: v2_company,
        files: quickbooks_history_uploads(suffix: " v2"),
        actor: v2_actor
      ).call.batch
    end
    v2_batch.historical_workers.find_each do |worker|
      worker.update!(private_snapshot: JSON.generate(worker.private_snapshot_data.except("_employee_directory")))
    end
    review_historical_workers_as_archive_only(v2_batch, actor: v2_actor)
    QuickbooksHistory::LifecycleService.new(batch: v2_batch, actor: v2_actor).apply!(
      acknowledgement: QuickbooksHistory::LifecycleService::ACKNOWLEDGEMENT
    )

    result = described_class.new(batch: v2_batch, actor: v2_actor).call

    expect(result.passed).to be(true)
    expect(result.review.evidence).to include(
      "importer_version" => "quickbooks-online-payroll-v2",
      "verification_parser_version" => QuickbooksHistory::BundleParser::IMPORTER_VERSION
    )
  end

  it "rejects an importer version outside the explicit compatibility set" do
    batch.update_column(:importer_version, "quickbooks-online-payroll-v1")

    expect { described_class.new(batch: batch, actor: actor).call }
      .to raise_error(ArgumentError, /unsupported.*reviewed source migration/i)
  end

  it "cannot persist over a newer queued verification attempt" do
    review = QuickbooksHistory::CutoverVerificationEnqueueService.new(batch: batch, actor: actor).call.review
    original_token = review.verification_started_at.iso8601(6)
    service = described_class.new(batch: batch, actor: actor, expected_verification_started_at: original_token)
    allow(service).to receive(:reparse_retained_sources!).and_wrap_original do |method|
      parsed = method.call
      review.update_columns(verification_started_at: 1.second.from_now)
      parsed
    end

    expect { service.call }.to raise_error(described_class::StaleVerificationAttempt)
    expect(review.reload).to be_pending
    expect(review.evidence).to eq({})
  end
end
