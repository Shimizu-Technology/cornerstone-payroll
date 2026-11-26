# frozen_string_literal: true

# Track B (Expand phase):
# - Adds companies.demo (boolean NOT NULL DEFAULT false) and validates the check
#   constraint that a flagged demo company runs in the live payroll environment.
# - Updates index_live_companies_on_ein to exclude demo companies so live EIN
#   uniqueness never collides with demo fixtures.
# - Widens index_demo_companies_on_organization_fixture_key to cover both legacy
#   test-workspace demos and new-shape live+demo companies that carry a fixture key.
#
# Existing demo companies stay on the legacy shape until the separate Migrate PR
# converts them and replaces the legacy constraints and triggers.
class AddDemoFlagToCompanies < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  DEMO_LIVE_CONSTRAINT = "companies_demo_requires_live_payroll"
  EIN_INDEX = "index_live_companies_on_ein"
  EIN_INDEX_TMP = "index_live_companies_on_ein_track_b_tmp"
  FIXTURE_INDEX = "index_demo_companies_on_organization_fixture_key"
  FIXTURE_INDEX_TMP = "index_demo_companies_on_org_fixture_key_track_b_tmp"

  def up
    with_lock_timeout do
      add_column :companies, :demo, :boolean, default: false, null: false, if_not_exists: true
      unless check_constraints(:companies).any? { |c| c.name == DEMO_LIVE_CONSTRAINT }
        add_check_constraint :companies,
                             "NOT demo OR payroll_environment = 'live'",
                             name: DEMO_LIVE_CONSTRAINT,
                             validate: false
      end
    end

    validate_check_constraint :companies, name: DEMO_LIVE_CONSTRAINT

    replace_ein_index!(where: "payroll_environment = 'live' AND NOT demo")
    replace_fixture_key_index!(
      where: "(demo = true OR COALESCE(test_workspace_purpose, '') = 'demo') AND COALESCE(test_workspace_manifest ->> 'demo_fixture_key', '') <> ''"
    )
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM companies WHERE demo = TRUE)")
      raise ActiveRecord::IrreversibleMigration, "Convert or remove companies with demo = true before rolling back this migration"
    end

    replace_fixture_key_index!(where: "COALESCE(test_workspace_purpose, '') = 'demo'")
    replace_ein_index!(where: "payroll_environment = 'live'")

    with_lock_timeout do
      remove_check_constraint :companies, name: DEMO_LIVE_CONSTRAINT, if_exists: true
      remove_column :companies, :demo, if_exists: true
    end
  end

  private

  def with_lock_timeout
    connection.transaction do
      execute "SET LOCAL lock_timeout = '5s'"
      yield
    end
  end

  def replace_ein_index!(where:)
    remove_index :companies, name: EIN_INDEX_TMP, algorithm: :concurrently, if_exists: true
    add_index :companies, :ein, unique: true, where: where, name: EIN_INDEX_TMP, algorithm: :concurrently
    remove_index :companies, name: EIN_INDEX, algorithm: :concurrently, if_exists: true
    with_lock_timeout do
      execute "ALTER INDEX #{quote_table_name(EIN_INDEX_TMP)} RENAME TO #{quote_table_name(EIN_INDEX)}"
    end
  end

  def replace_fixture_key_index!(where:)
    remove_index :companies, name: FIXTURE_INDEX_TMP, algorithm: :concurrently, if_exists: true
    add_index :companies,
              "organization_id, (test_workspace_manifest ->> 'demo_fixture_key')",
              unique: true,
              where: where,
              name: FIXTURE_INDEX_TMP,
              algorithm: :concurrently
    remove_index :companies, name: FIXTURE_INDEX, algorithm: :concurrently, if_exists: true
    with_lock_timeout do
      execute "ALTER INDEX #{quote_table_name(FIXTURE_INDEX_TMP)} RENAME TO #{quote_table_name(FIXTURE_INDEX)}"
    end
  end
end
