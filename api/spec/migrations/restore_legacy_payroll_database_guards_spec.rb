# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261015010000_restore_legacy_payroll_database_guards")

RSpec.describe RestoreLegacyPayrollDatabaseGuards do
  let(:connection) { ApplicationRecord.connection }
  let(:migration) { described_class.new }
  let(:company) { create(:company) }
  let!(:owner) do
    create(:user, company: company, email: User::PRIMARY_PLATFORM_OWNER_EMAIL,
      role: "super_admin", platform_owner: true)
  end
  let!(:comparison) { create(:pay_period, company: company, parallel_run: true) }
  let!(:employee) { create(:employee, company: company) }
  let!(:item) { create(:payroll_item, pay_period: comparison, employee: employee, company: company, gross_pay: 123.45, net_pay: 100.01) }
  let!(:earning) { item.payroll_item_earnings.create!(category: "regular", label: "Retained earning", hours: 3, amount: 123.45) }
  let!(:ytd) { EmployeeYtdTotal.create!(employee: employee, year: 2024, gross_pay: 123.45, net_pay: 100.01) }

  def drop_legacy_guards
    connection.execute(<<~SQL)
      DROP TRIGGER IF EXISTS protect_primary_platform_owner_delete ON users;
      DROP TRIGGER IF EXISTS pay_periods_parallel_run_immutable ON pay_periods;
      DROP FUNCTION IF EXISTS prevent_primary_platform_owner_delete();
      DROP FUNCTION IF EXISTS prevent_pay_period_parallel_run_clear();
    SQL
  end

  def saved_rows
    %w[users employees pay_periods payroll_items payroll_item_earnings employee_ytd_totals audit_logs schema_migrations].to_h do |table|
      [ table, connection.select_value("SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, E'\\n' ORDER BY to_jsonb(t)::text), '')) FROM #{table} t") ]
    end
  end

  def reject_without_aborting_transaction(sql, message)
    expect do
      connection.transaction(requires_new: true) { connection.execute(sql) }
    end.to raise_error(ActiveRecord::StatementInvalid, message)
  end

  it "protects schema-loaded rows before any forward guard repair is invoked" do
    guards = connection.select_rows(<<~SQL)
      SELECT tgname, tgenabled::text FROM pg_trigger
      WHERE (tgrelid = 'users'::regclass AND tgname = 'protect_primary_platform_owner_delete')
         OR (tgrelid = 'pay_periods'::regclass AND tgname = 'pay_periods_parallel_run_immutable')
    SQL
    expect(guards).to match_array([
      [ "protect_primary_platform_owner_delete", "O" ], [ "pay_periods_parallel_run_immutable", "O" ]
    ])
    before = saved_rows
    reject_without_aborting_transaction("DELETE FROM users WHERE id = #{owner.id}", /primary platform owner cannot be deleted/)
    reject_without_aborting_transaction("UPDATE pay_periods SET parallel_run = FALSE WHERE id = #{comparison.id}", /parallel_run cannot be cleared/)
    expect(saved_rows).to eq(before)
  end

  it "repairs a populated database with applied historical versions without rewriting retained rows" do
    historical_versions = connection.select_values("SELECT version FROM schema_migrations")
    expect(historical_versions).to include("20260717120000", "20260908120000")
    drop_legacy_guards
    before = saved_rows
    other_guards = connection.select_rows("SELECT tgname, pg_get_triggerdef(oid), tgenabled::text FROM pg_trigger WHERE NOT tgisinternal ORDER BY tgrelid, tgname")
    migration.migrate(:up)
    migration.migrate(:up)
    expect(saved_rows).to eq(before)
    expect(connection.select_rows(<<~SQL)).to eq(other_guards)
      SELECT tgname, pg_get_triggerdef(oid), tgenabled::text FROM pg_trigger
      WHERE NOT tgisinternal AND tgname NOT IN ('protect_primary_platform_owner_delete', 'pay_periods_parallel_run_immutable')
      ORDER BY tgrelid, tgname
    SQL
    guards = connection.select_rows(<<~SQL)
      SELECT tgname, tgenabled::text FROM pg_trigger
      WHERE (tgrelid = 'users'::regclass AND tgname = 'protect_primary_platform_owner_delete')
         OR (tgrelid = 'pay_periods'::regclass AND tgname = 'pay_periods_parallel_run_immutable')
    SQL
    expect(guards).to match_array([
      [ "protect_primary_platform_owner_delete", "O" ], [ "pay_periods_parallel_run_immutable", "O" ]
    ])

    reject_without_aborting_transaction("DELETE FROM users WHERE id = #{owner.id}", /primary platform owner cannot be deleted/)
    reject_without_aborting_transaction("UPDATE pay_periods SET parallel_run = FALSE WHERE id = #{comparison.id}", /parallel_run cannot be cleared/)
    expect(saved_rows).to eq(before)
    expect(item.reload.net_pay).to eq(BigDecimal("100.01"))
  end

  it "preserves ordinary deletion, updates and entry into comparison mode" do
    drop_legacy_guards
    migration.migrate(:up)
    ordinary = create(:user, company: company)
    ordinary_period = create(:pay_period, company: company)
    connection.execute("DELETE FROM users WHERE id = #{ordinary.id}")
    connection.execute("UPDATE pay_periods SET parallel_run = FALSE WHERE id = #{ordinary_period.id}")
    connection.execute("UPDATE pay_periods SET parallel_run = TRUE WHERE id = #{ordinary_period.id}")
    connection.execute("UPDATE pay_periods SET notes = 'Reviewed comparison' WHERE id = #{comparison.id}")
    expect(User.exists?(ordinary.id)).to be(false)
    expect(ordinary_period.reload.parallel_run).to be(true)
    expect(comparison.reload.notes).to eq("Reviewed comparison")
    expect(owner.reload.platform_owner).to be(true)
    expect(item.reload.net_pay).to eq(BigDecimal("100.01"))
  end

  it "reinstates origin-write guards when retained triggers are replica-only" do
    migration.migrate(:up)
    connection.execute("ALTER TABLE users ENABLE REPLICA TRIGGER protect_primary_platform_owner_delete")
    connection.execute("ALTER TABLE pay_periods ENABLE REPLICA TRIGGER pay_periods_parallel_run_immutable")
    migration.migrate(:up)
    reject_without_aborting_transaction("DELETE FROM users WHERE id = #{owner.id}", /primary platform owner cannot be deleted/)
    reject_without_aborting_transaction("UPDATE pay_periods SET parallel_run = FALSE WHERE id = #{comparison.id}", /parallel_run cannot be cleared/)
  end

  it "cannot remove restored protection on rollback" do
    expect { migration.migrate(:down) }.to raise_error(ActiveRecord::IrreversibleMigration, /Retain primary owner/)
  end
end
