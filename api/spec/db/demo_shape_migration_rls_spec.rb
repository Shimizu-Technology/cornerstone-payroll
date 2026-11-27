# frozen_string_literal: true

require "rails_helper"

require Rails.root.join("db/migrate/20261127170000_prepare_demo_company_shape_migration")

RSpec.describe "PrepareDemoCompanyShapeMigration RLS staging" do
  let(:connection) { ActiveRecord::Base.connection }
  let(:table_name) { "demo_shape_conversions" }

  def database_before_migration!(enforced:)
    RlsDatabase.install!(connection)
    if enforced
      (RlsTables::PROTECTED_TABLES - [ table_name ]).each do |table|
        connection.execute("ALTER TABLE #{connection.quote_table_name(table)} ENABLE ROW LEVEL SECURITY")
        connection.execute("ALTER TABLE #{connection.quote_table_name(table)} FORCE ROW LEVEL SECURITY")
      end
    end
    %w[company_isolation company_select company_insert company_update company_delete].each do |policy|
      connection.execute("DROP POLICY IF EXISTS #{policy} ON #{table_name}")
    end
    connection.execute("ALTER TABLE #{table_name} NO FORCE ROW LEVEL SECURITY")
    connection.execute("ALTER TABLE #{table_name} DISABLE ROW LEVEL SECURITY")
  end

  def stage!
    ActiveRecord::Migration.suppress_messages do
      PrepareDemoCompanyShapeMigration.new.send(:stage_company_policy, :demo_shape_conversions)
    end
  end

  def row
    RlsDatabase.table_status(connection).find { |entry| entry["table"] == table_name }
  end

  it "registers demo_shape_conversions as company-protected" do
    expect(RlsTables::PROTECTED_TABLES).to include(table_name)
    expect(RlsTables::RLS_EXEMPT_TABLES).not_to include(table_name)
  end

  it "stages the policy and stays in shadow mode on a shadow database" do
    database_before_migration!(enforced: false)
    expect(EmployeeAppSwitch::Enforcement.database_state[:phase]).to eq("not_installed")

    stage!
    expect(row).to include("policy" => true, "enabled" => false, "forced" => false)
    expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "shadow", enforced: false)
  end

  it "enables and forces RLS on demo_shape_conversions when the database is already enforced" do
    database_before_migration!(enforced: true)
    expect(EmployeeAppSwitch::Enforcement.database_state[:phase]).to eq("not_installed")

    stage!
    expect(row).to include("policy" => true, "enabled" => true, "forced" => true)
    expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "enforced", enforced: true)
  end
end
