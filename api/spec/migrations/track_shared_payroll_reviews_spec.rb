# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261102010000_track_shared_payroll_reviews")

RSpec.describe TrackSharedPayrollReviews do
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

    migration = described_class.new
    migration.down
    migration.up

    expect(visible.reload.sent_for_client_approval_at).to be_present
    expect(visible.client_review_history_unknown?).to be(false)
    [ superseded, invisible, disabled ].each do |package|
      expect(package.reload.sent_for_client_approval_at).to be_nil
      expect(package.client_review_history_unknown?).to be(true)
      expect(package.retained_client_evidence?).to be(true)
    end
    expect(disabled_run.deletion_blocker).to include("unverified sharing history")
  end
end
