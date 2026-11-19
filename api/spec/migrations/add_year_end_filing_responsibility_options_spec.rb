# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261119120000_add_year_end_filing_responsibility_options")

RSpec.describe AddYearEndFilingResponsibilityOptions do
  let(:migration) { described_class.new.tap { |instance| instance.verbose = false } }
  let(:connection) { ActiveRecord::Base.connection }
  let(:company) { create(:company) }

  after { PayrollFilingResponsibility.reset_column_information }

  def record(**attributes)
    create(:payroll_filing_responsibility, :annual, company: company, **attributes)
  end

  it "refuses to roll back while year-end rows would violate the old constraints, and keeps them" do
    kept = record(filing_type: "form_1099", responsible_party: "no_filing")

    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration, /1 payroll filing responsibility row\(s\) use year-end options/)
    expect(PayrollFilingResponsibility.find(kept.id).responsible_party).to eq("no_filing")
    expect(connection.column_exists?(:payroll_filing_responsibilities, :prior_provider_through)).to be(true)
  end

  it "refuses a prior-provider date too" do
    record(prior_provider_through: Date.new(2026, 3, 31))

    expect { migration.down }.to raise_error(ActiveRecord::IrreversibleMigration)
  end

  it "rolls back and reapplies when only original options are in use" do
    record

    migration.down
    expect(connection.column_exists?(:payroll_filing_responsibilities, :prior_provider_through)).to be(false)
    migration.up
    expect(connection.column_exists?(:payroll_filing_responsibilities, :prior_provider_through)).to be(true)
  end
end
