# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261117150000_add_payroll_review_change_requests")

RSpec.describe AddPayrollReviewChangeRequests do
  it "recognizes only already shared current reviews on staff-approved runs at rollout" do
    company = create(:company)
    packages = %w[approved calculated committed].to_h do |status|
      period = create(:pay_period, company: company, status: status)
      [ status, period.payroll_review_packages.create!(company: company, revision: 1,
        calculation_checksum: "a" * 64, schema_version: "v1", generated_at: Time.current,
        sent_for_client_approval_at: 1.day.ago, client_review_history_unknown: false) ]
    end
    migration = described_class.new
    suppress_messages { migration.migrate(:down); migration.migrate(:up) }
    PayrollReviewPackage.reset_column_information
    expect(packages.fetch("approved").reload.published_at).to eq(packages.fetch("approved").sent_for_client_approval_at)
    expect(packages.fetch("calculated").reload.published_at).to be_nil
    expect(packages.fetch("committed").reload.published_at).to be_nil
  end

  def suppress_messages
    ActiveRecord::Migration.suppress_messages { yield }
  end
end
