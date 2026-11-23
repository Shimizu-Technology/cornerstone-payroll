# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261123150500_keep_import_rollout_digest_stable")

RSpec.describe TimeTrackingLockRolloutSelection do
  let(:source) { create(:time_tracking_source, source_type: "aire_services") }
  let(:attributes) { { time_tracking_source: source, starts_on: "2026-11-01", actor: "Reviewed operator", reason: "Approved later initial Stage 2 rollout" } }

  it "retains the original column and refuses SQL updates, deletion and truncation of the appended decision" do
    selection = described_class.create!(attributes)
    expect(source.reload[:cutoff_enforcement_starts_on]).to eq(Date.new(2026, 10, 16))
    expect(source.cutoff_enforcement_starts_on).to eq(Date.new(2026, 11, 1))
    [ -> { described_class.where(id: selection.id).update_all(starts_on: "2026-11-16") },
      -> { selection.delete },
      -> { described_class.connection.execute("TRUNCATE time_tracking_lock_rollout_selections") } ].each do |mutation|
      expect { described_class.transaction(requires_new: true) { mutation.call } }
        .to raise_error(ActiveRecord::StatementInvalid, /immutable/)
    end
  end

  it "rejects an earlier initial selection at the database boundary" do
    expect { described_class.transaction(requires_new: true) { described_class.create!(attributes.merge(starts_on: "2026-10-01")) } }
      .to raise_error(ActiveRecord::StatementInvalid, /must be later/)
  end

  it "rejects selection after the existing explicit rollout gate" do
    AirePayrollCalendar::LockRollout.new(source: source, starts_on: "2026-10-16", actor: "Reviewed operator", reason: "Approved original October rollout").configure!
    expect { described_class.transaction(requires_new: true) { described_class.create!(attributes) } }
      .to raise_error(ActiveRecord::StatementInvalid, /unused, ungated/)
  end

  it "rejects selection after any rollout receipt, including unverified coverage" do
    source.aire_verified_history_rollout_receipts.create!(company: source.company,
      manifest_sha256: "a" * 64, coverage_verified: false, identity_count: 0, paid_source_entry_count: 0, completed_at: Time.current)
    expect { described_class.transaction(requires_new: true) { described_class.create!(attributes) } }
      .to raise_error(ActiveRecord::StatementInvalid, /unused, ungated/)
  end

  it "rejects selection after an import, including a preview" do
    period = create(:pay_period, company: source.company)
    create(:time_tracking_import, time_tracking_source: source, pay_period: period)
    expect { described_class.transaction(requires_new: true) { described_class.create!(attributes) } }
      .to raise_error(ActiveRecord::StatementInvalid, /exact reviewed/)
  end

  it "accepts the same reviewed import digest after adding and backfilling company ownership" do
    period = create(:pay_period, :committed, company: source.company, start_date: "2026-09-01",
      end_date: "2026-09-14", pay_date: "2026-09-16", committed_at: Time.zone.parse("2026-09-16"))
    import = create(:time_tracking_import, pay_period: period, time_tracking_source: source,
      raw_payload: { "source" => "aire_services" }, created_at: Time.zone.parse("2026-09-15"))
    connection = ApplicationRecord.connection
    migration = KeepImportRolloutDigestStable.new
    review = AirePayrollCalendar::HistoricalImportBoundaryReview.new(source: source)

    # Recreate the pre-expand layout inside this example's transaction.
    connection.execute("DROP POLICY company_isolation ON aire_payroll_acknowledgements")
    connection.execute("DROP POLICY company_isolation ON time_tracking_imports")
    connection.remove_column :time_tracking_imports, :company_id
    connection.clear_cache!
    migration.down
    before_expand = review.preview!
    expect(before_expand.fetch("inventory").sole.fetch("import_id")).to eq(import.id)

    connection.add_column :time_tracking_imports, :company_id, :bigint
    connection.clear_cache!
    migration.up
    expect(review.preview!).to eq(before_expand)
    expect(PayrollChildCompanyBackfill.new(connection: connection).backfill.fetch(:time_tracking_imports)).to eq(1)
    expect(review.preview!).to eq(before_expand)
    expect(described_class.create!(attributes.merge(historical_import_review: before_expand)).historical_import_review)
      .to eq(before_expand)
  end

  it "rejects selection while any source calendar already exists" do
    period = create(:pay_period, company: source.company)
    create(:aire_payroll_calendar_period, company: source.company, time_tracking_source: source, pay_period: period)
    expect { described_class.transaction(requires_new: true) { described_class.create!(attributes) } }
      .to raise_error(ActiveRecord::StatementInvalid, /unused, ungated/)
  end
end
