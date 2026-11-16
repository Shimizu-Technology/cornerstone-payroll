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

  it "keeps explicit links after date edits and after another same-date run is created" do
    target = run
    period = files_period
    other = run
    expect(period.reload.pay_period_id).to eq(target.id)
    catalog = PayrollSubmissions::Catalog.new(company: company)
    expect(catalog.live_pay_period(catalog.resolve(period.id))).to eq(target)
    target.update_columns(start_date: dates[:start_date] - 1)
    expect(catalog.live_pay_period(catalog.resolve(period.id))).to eq(target)
    expect(other.outstanding_client_file_requests).to be_empty
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
end
