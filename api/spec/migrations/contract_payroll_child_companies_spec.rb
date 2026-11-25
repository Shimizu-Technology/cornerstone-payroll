# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261126070000_contract_payroll_child_companies")

RSpec.describe ContractPayrollChildCompanies do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new.tap { |instance| instance.verbose = false } }
  let(:tables) { M3_7ChildCompanies::CHILDREN.keys.map(&:to_s) }

  def nullable
    RlsEnforcement.nullable_child_companies(connection)
  end

  def checks
    connection.select_values("SELECT conname FROM pg_constraint WHERE conname LIKE '%_company_id_present'")
  end

  it "refuses to require company_id while a promoted child row has none, then contracts every child" do
    migration.migrate(:down)
    expect(nullable).to match_array(tables)

    total = DepartmentYtdTotal.create!(department: create(:department), year: 2026)
    total.update_columns(company_id: nil)
    expect { migration.migrate(:up) }.to raise_error(described_class::MissingCompanyError,
      /company_id is NULL on department_ytd_totals\. Backfill/)
    expect(nullable).to match_array(tables)
    expect(checks).to be_empty

    total.update_columns(company_id: total.department.company_id)
    migration.migrate(:up)
    expect(nullable).to be_empty
    expect(checks).to be_empty
    # The fill trigger still supplies the company before NOT NULL is checked.
    expect(DepartmentYtdTotal.create!(department: create(:department), year: 2027).reload.company_id).to be_present
  end

  it "reports a NULL that appears after the pre-check by its table" do
    migration.migrate(:down)
    total = DepartmentYtdTotal.create!(department: create(:department), year: 2026)
    allow(migration).to receive(:refuse_missing_companies!)
    total.update_columns(company_id: nil)

    expect { migration.migrate(:up) }.to raise_error(described_class::MissingCompanyError, /department_ytd_totals/)
    expect(nullable).to include("department_ytd_totals")
  end

  it "retries a short lock wait instead of failing the deploy" do
    migration.migrate(:down)
    timeouts = 2
    allow(migration).to receive(:sleep)
    allow(migration).to receive(:with_short_ddl_transaction).and_wrap_original do |original, &block|
      if timeouts.positive?
        timeouts -= 1
        raise ActiveRecord::LockWaitTimeout
      end
      original.call(&block)
    end

    migration.migrate(:up)
    expect(nullable).to be_empty
    expect(migration).to have_received(:sleep).with(1).once
    expect(migration).to have_received(:sleep).with(2).once
  end

  it "skips tables that already require company_id" do
    expect(nullable).to be_empty
    migration.migrate(:up)
    expect(nullable).to be_empty
  end
end
