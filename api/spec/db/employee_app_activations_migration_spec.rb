# frozen_string_literal: true

require "rails_helper"

require Rails.root.join("db/migrate/20261126060400_create_employee_app_activations")

# M4-9d: the migration that adds the employee app's protected tables stages
# their company policies and follows the database's current enforcement
# phase, so an incremental migration never leaves RLS readiness reading
# "not_installed" (or "partial").
RSpec.describe "Employee app activations migration RLS staging" do
  let(:connection) { ActiveRecord::Base.connection }
  let(:new_tables) { CreateEmployeeAppActivations::PROTECTED }

  # The state an incremental migration meets: every earlier protected table
  # installed (and enforced or not), the new tables just created bare.
  def database_before_migration!(enforced:)
    RlsDatabase.install!(connection)
    if enforced
      (RlsTables::PROTECTED_TABLES - new_tables).each do |table|
        connection.execute("ALTER TABLE #{connection.quote_table_name(table)} ENABLE ROW LEVEL SECURITY")
        connection.execute("ALTER TABLE #{connection.quote_table_name(table)} FORCE ROW LEVEL SECURITY")
      end
    end
    new_tables.each do |table|
      %w[company_isolation company_select company_insert company_update company_delete].each do |policy|
        connection.execute("DROP POLICY IF EXISTS #{policy} ON #{table}")
      end
      connection.execute("ALTER TABLE #{table} NO FORCE ROW LEVEL SECURITY")
      connection.execute("ALTER TABLE #{table} DISABLE ROW LEVEL SECURITY")
    end
  end

  def stage!
    ActiveRecord::Migration.suppress_messages { CreateEmployeeAppActivations.new.send(:stage_company_policies!) }
  end

  def rows
    RlsDatabase.table_status(connection).select { |row| new_tables.include?(row["table"]) }
  end

  it "registers both new tables as company-protected" do
    expect(RlsTables::PROTECTED_TABLES).to include(*new_tables)
    expect(RlsTables::RLS_EXEMPT_TABLES).not_to include(*new_tables)
  end

  it "stages the policies and stays in shadow mode on a shadow database" do
    database_before_migration!(enforced: false)
    expect(EmployeeAppSwitch::Enforcement.database_state[:phase]).to eq("not_installed")

    stage!
    expect(rows).to all(include("policy" => true, "enabled" => false, "forced" => false))
    expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "shadow", enforced: false)
  end

  it "enables and forces the new tables on a database that already enforces RLS" do
    database_before_migration!(enforced: true)
    expect(EmployeeAppSwitch::Enforcement.database_state[:phase]).to eq("not_installed")

    stage!
    expect(rows).to all(include("policy" => true, "enabled" => true, "forced" => true))
    expect(EmployeeAppSwitch::Enforcement.database_state).to include(phase: "enforced", enforced: true)
  end
end
