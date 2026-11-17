# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117160000_link_unambiguous_payroll_submission_periods")

RSpec.describe PayrollSubmissionPeriod, type: :model do
  let(:company) { create(:company) }
  let(:dates) { { start_date: Date.new(2026, 11, 2), end_date: Date.new(2026, 11, 15) } }
  def files_period
    described_class.create!(company: company, **dates, source: "schedule")
  end
  def run(**attributes)
    create(:pay_period, company: company, **dates, pay_date: Date.new(2026, 11, 20), **attributes)
  end

  it "links when the files period is created after its run" do
    target = run
    expect(files_period.pay_period_id).to eq(target.id)
  end

  it "links when the run is created after its files period" do
    period = files_period
    expect(period.pay_period_id).to be_nil
    target = run
    expect(period.reload.pay_period_id).to eq(target.id)
  end

  def retain_selection(period, target)
    actor = create(:user, company: company)
    source = period.submissions.create!(company: company, revision: 1, submitted_by: actor, submitted_at: Time.current,
      content_fingerprint: "link-source", request_fingerprint: "link-source")
    import = PayrollImportRecord.create!(pay_period: target, status: "previewed")
    PayrollSubmissionImport.create!(payroll_import: import, payroll_submission: source, current_submission: source,
      selected_by: actor, source_route: "portal")
    source
  end

  it "lets staff delete an auto-linked draft while preserving the client's submitted source" do
    period = files_period
    actor = create(:user, company: company)
    source = period.submissions.create!(company: company, revision: 1, submitted_by: actor, submitted_at: Time.current,
      content_fingerprint: "client-upload", request_fingerprint: "client-upload")
    target = run
    expect(period.reload.pay_period_id).to eq(target.id)
    expect { target.destroy! }.not_to raise_error
    expect(period.reload.pay_period_id).to be_nil
    expect(source.reload.period).to eq(period)
  end

  it "preserves selected import evidence and refuses deletion" do
    target = run
    period = files_period
    retain_selection(period, target)
    target.update!(start_date: dates[:start_date] - 1, run_purpose: "bonus")
    expect(period.reload.pay_period_id).to eq(target.id)
    expect { target.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed) { |error| expect(error.record.errors.full_messages.join).to include("retained client file") }
    expect(period.reload.pay_period_id).to eq(target.id)
  end

  it "releases an automatic link after a purpose change and links the real regular run" do
    target = run
    period = files_period
    target.update!(run_purpose: "bonus")
    expect(period.reload.pay_period_id).to be_nil
    expect(target.pending_portal_submission?).to be(false)
    replacement = run
    expect(period.reload.pay_period_id).to eq(replacement.id)
    expect { target.destroy! }.not_to raise_error
  end

  it "releases an automatic link after date edits and rematches both affected periods" do
    target = run
    period = files_period
    replacement = run
    next_period = described_class.create!(company: company, start_date: dates[:start_date] + 14,
      end_date: dates[:end_date] + 14, source: "schedule")
    target.update!(start_date: next_period.start_date, end_date: next_period.end_date, pay_date: next_period.end_date + 5)
    expect(period.reload.pay_period_id).to eq(replacement.id)
    expect(next_period.reload.pay_period_id).to eq(target.id)
  end

  it "does not take the company creation lock for correction, supplemental or bonus runs" do
    original = run
    expect(Company).not_to receive(:lock)
    run(cycle: "supplemental", corrects_pay_period: original)
    run(run_purpose: "bonus")
    run(correction_status: "correction", source_pay_period: original)
  end

  it "keeps an automatic link when a same-date duplicate is created, until the original dates change" do
    target = run
    period = files_period
    run
    expect(period.reload.pay_period_id).to eq(target.id)
  end

  it "never claims an occupied run in live linking, catalog materialization or repeated backfills" do
    target = run
    first = files_period
    changed = { start_date: dates[:start_date] + 1, end_date: dates[:end_date] + 1 }
    target.update_columns(**changed) # Legacy authoritative link with different dates.
    catalog = PayrollSubmissions::Catalog.new(company: company, today: Date.new(2026, 11, 17))
    entry = catalog.resolve(PayrollSubmissionPeriod.ref_for(changed[:start_date], changed[:end_date]))
    expect(entry).to be_present
    expect { catalog.materialize!(entry) }.not_to raise_error
    second = entry.record
    expect(second.reload.pay_period_id).to be_nil
    expect { PayrollSubmissions::LinkPayPeriod.call(second) }.not_to raise_error
    2.times { ActiveRecord::Migration.suppress_messages { LinkUnambiguousPayrollSubmissionPeriods.new.migrate(:up) } }
    expect(second.reload.pay_period_id).to be_nil
    expect(first.reload.pay_period_id).to eq(target.id)
  end

  it "excludes parallel comparison runs from linking and date ambiguity" do
    run(parallel_run: true)
    target = run
    expect(files_period.pay_period_id).to eq(target.id)
  end

  it "surfaces ambiguous unlinked dates in both single and batched catalogs" do
    first = run
    second = run
    period = files_period
    expect(period.pay_period_id).to be_nil
    catalog = PayrollSubmissions::Catalog.new(company: company, today: Date.new(2026, 11, 17))
    entry = catalog.resolve(period.id)
    expect(catalog.live_pay_period(entry)).to be_nil
    expect(catalog.ambiguous_pay_period_ids(entry)).to eq([ first.id, second.id ])
    catalog.preload_live_pay_periods([ entry ])
    expect(catalog.live_pay_period(entry)).to be_nil
    expect(catalog.ambiguous_pay_period_ids(entry)).to eq([ first.id, second.id ])
    expect(catalog.entries.find { |e| e.record == period }.pay_period).to be_nil
  end

  it "backfills only unique eligible runs, preserves links and is idempotent" do
    target = run
    period = files_period
    period.reload.update_column(:pay_period_id, nil)
    unrelated = create(:company)
    create(:pay_period, company: unrelated, **dates, pay_date: Date.new(2026, 11, 20))
    migration = LinkUnambiguousPayrollSubmissionPeriods.new
    2.times { ActiveRecord::Migration.suppress_messages { migration.migrate(:up) } }
    expect(period.reload.pay_period_id).to eq(target.id)
    run
    period.reload.update_column(:pay_period_id, nil)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(period.reload.pay_period_id).to be_nil
    period.update!(pay_period: target)
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
    expect(period.reload.pay_period_id).to eq(target.id)
  end

  it "leaves periods without eligible runs unlinked, including during backfill" do
    period = files_period
    voided = run
    supplemental = run(cycle: "supplemental", run_purpose: "correction", corrects_pay_period: voided)
    voided.update_column(:correction_status, "voided")
    period.reload.update_column(:pay_period_id, nil)
    expect(supplemental.reload.cycle).to eq("supplemental")
    expect(PayPeriod.portal_submission_runs.where(company_id: company.id)).to be_empty
    ActiveRecord::Migration.suppress_messages { LinkUnambiguousPayrollSubmissionPeriods.new.migrate(:up) }
    expect(period.reload.pay_period_id).to be_nil
    PayrollSubmissions::LinkPayPeriod.call(period)
    expect(period.reload.pay_period_id).to be_nil
  end

  it "links a newly created unique replacement for a voided run explicitly" do
    target = run
    period = files_period
    target.update_column(:correction_status, "voided")
    catalog = PayrollSubmissions::Catalog.new(company: company)
    expect(catalog.live_pay_period(catalog.resolve(period.id))).to be_nil
    replacement = run
    expect(period.reload.pay_period_id).to eq(replacement.id)
    expect(catalog.live_pay_period(catalog.resolve(period.id))).to eq(replacement)
    expect(catalog.ambiguous_pay_period_ids(catalog.resolve(period.id))).to be_empty
  end
  it "backfills a unique free replacement for a legacy voided link" do
    previous = run
    period = files_period
    replacement = run
    previous.update_column(:correction_status, "voided")
    2.times { ActiveRecord::Migration.suppress_messages { LinkUnambiguousPayrollSubmissionPeriods.new.migrate(:up) } }
    expect(period.reload.pay_period_id).to eq(replacement.id)
  end

  it "warns staff when a voided linked run has no unique replacement" do
    previous = run
    period = files_period
    previous.update_column(:correction_status, "voided")
    run
    run
    period.reload.update_column(:pay_period_id, previous.id) # Legacy ambiguity retained for rollout.
    ActiveRecord::Migration.suppress_messages { LinkUnambiguousPayrollSubmissionPeriods.new.migrate(:up) }
    catalog = PayrollSubmissions::Catalog.new(company: company)
    entry = catalog.resolve(period.id)
    expect(catalog.live_pay_period(entry)).to be_nil
    expect(catalog.retired_link_warning(entry)).to include(previous.id.to_s, "voided", "replacement")
    staff = create(:user, company: company, role: "admin")
    payload = PayrollSubmissions::Serializer.new(current_user: staff, catalog: catalog).summary(entry)
    expect(payload[:pay_period_link_error]).to include("voided")
  end
end
