# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261114130000_create_payroll_standing_changes")

RSpec.describe CreatePayrollStandingChanges do
  it "refuses rollback before changing populated skipped revision evidence or defaults" do
    company = create(:company)
    actor = create(:user, company: company)
    owner = create(:employee, :salary, company: company, salary_type: "variable", pay_rate: 0)
    default = PayrollStandingChange.create!(company: company, employee: owner, kind: "owner_pay")
    run = create(:pay_period, company: company)
    period = PayrollSubmissionPeriod.create!(company: company, pay_period: run, source: "pay_period", start_date: run.start_date, end_date: run.end_date)
    revision = period.submissions.create!(company: company, revision: 1, submitted_by: actor, submitted_at: Time.current,
      no_changes: true, change_rows: [ { "kind" => "owner_pay", "employee_id" => owner.id, "standing_change_id" => default.id, "skipped" => true } ],
      content_fingerprint: SecureRandom.hex(32), request_fingerprint: SecureRandom.hex(32))
    original = revision.attributes
    expect { described_class.new.migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /application code only/)
    expect(revision.reload.attributes).to eq(original)
    expect(default.reload).to be_active
    expect(ActiveRecord::Base.connection.check_constraint_exists?(:payroll_submissions, name: "payroll_submissions_no_changes_is_empty")).to be(true)
  end
end
