# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261102010000_track_shared_payroll_reviews")

RSpec.describe TrackSharedPayrollReviews do
  after do
    PayrollReviewPackage.reset_column_information
    ApplicationRecord.connection.clear_cache!
  end
  it "retains unknown legacy visibility and positively stamps only visible current revisions" do
    company = create(:company, client_payroll_approval_required: true)
    visible_run = create(:pay_period, :calculated, company: company)
    invisible_run = create(:pay_period, company: company)
    other_company = create(:company, client_payroll_approval_required: false)
    disabled_run = create(:pay_period, :calculated, company: other_company)
    attributes = { schema_version: "1", calculation_checksum: "a" * 64, generated_at: Time.current }
    visible = visible_run.payroll_review_packages.create!(**attributes, company: company, revision: 2)
    superseded = visible_run.payroll_review_packages.create!(**attributes, company: company, revision: 1, status: "superseded", superseded_at: Time.current, supersession_reason: "Replaced before migration")
    invisible = invisible_run.payroll_review_packages.create!(**attributes, company: company, revision: 1)
    disabled = disabled_run.payroll_review_packages.create!(**attributes, company: other_company, revision: 1)
    item = create(:payroll_item, company: other_company, pay_period: disabled_run, hours_worked: 17)

    migration = described_class.new
    migration.down
    migration.up
    PayrollReviewPackage.reset_column_information
    ApplicationRecord.connection.clear_cache!

    expect(visible.reload.sent_for_client_approval_at).to be_present
    expect(visible.client_review_history_unknown?).to be(false)
    [ superseded, invisible, disabled ].each do |package|
      expect(package.reload.sent_for_client_approval_at).to be_nil
      expect(package.client_review_history_unknown?).to be(true)
      expect(package.retained_client_evidence?).to be(true)
    end
    expect(disabled_run.deletion_blocker).to include("unverified sharing history")
    records = [ other_company, disabled_run, disabled, item ]
    before = records.map { |record| record.reload.attributes }
    expect { disabled_run.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(records.map { |record| record.class.find(record.id).attributes }).to eq(before)

    # Only the new issuer can positively identify an unshared package after
    # the migration boundary; null historical timestamps alone cannot do so.
    fresh_run = create(:pay_period, :calculated, company: other_company)
    fresh_item = create(:payroll_item, company: other_company, pay_period: fresh_run)
    fresh_package = PayrollReview::RevisionService.new(pay_period: fresh_run).issue!
    expect(fresh_package).to have_attributes(client_review_history_unknown: false, sent_for_client_approval_at: nil)
    expect { fresh_run.destroy! }.not_to raise_error
    expect(PayPeriod.exists?(fresh_run.id)).to be(false)
    expect(PayrollItem.exists?(fresh_item.id)).to be(false)
    expect(PayrollReviewPackage.exists?(fresh_package.id)).to be(false)
  end

  it "retains publication by an old writer that bypasses model callbacks" do
    company = create(:company, client_payroll_approval_required: false)
    run = create(:pay_period, :calculated, company: company)
    item = create(:payroll_item, company: company, pay_period: run, hours_worked: 17)
    package = run.payroll_review_packages.create!(company: company, revision: 1,
      schema_version: "1", calculation_checksum: "a" * 64, generated_at: Time.current,
      client_review_history_unknown: false)

    # Emulate the old application's UPDATE statements with no new callbacks.
    Company.where(id: company.id).update_all(client_payroll_approval_required: true)
    Company.where(id: company.id).update_all(client_payroll_approval_required: false)

    expect(package.reload.sent_for_client_approval_at).to be_present
    expect(package.client_review_history_unknown?).to be(false)
    expect { run.destroy! }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(item.reload.hours_worked).to eq(17)
    expect(package.reload).to be_persisted
  end
end
