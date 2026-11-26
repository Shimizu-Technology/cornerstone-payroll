# frozen_string_literal: true

# Track B (Expand phase):
# - Adds companies.demo (boolean NOT NULL DEFAULT false) and validates the check
#   constraint that a flagged demo company runs in the live payroll environment.
# - Updates index_live_companies_on_ein to exclude demo companies so live EIN
#   uniqueness never collides with demo fixtures.
# - Widens index_demo_companies_on_organization_fixture_key to cover both legacy
#   test-workspace demos and new-shape live+demo companies that carry a fixture key.
#
# Index swaps are retry-safe: they inspect pg_index/pg_class, preserve a VALID
# temporary replacement across retries, rebuild only INVALID or stale builds,
# never drop the live index before a valid replacement exists, and bound lock
# waits with a session-level lock_timeout restored in ensure.
#
# Existing demo companies stay on the legacy shape until the separate Migrate PR
# converts them and replaces the legacy constraints and triggers.
class AddDemoFlagToCompanies < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s"
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

    with_session_lock_timeout do
      validate_check_constraint :companies, name: DEMO_LIVE_CONSTRAINT

      swap_index_concurrently!(
        target_name: EIN_INDEX,
        tmp_name: EIN_INDEX_TMP,
        columns: :ein,
        where: "payroll_environment = 'live' AND NOT demo",
        matches_target: ->(definition) { where_clause(definition).match?(/\bNOT\s+demo\b/i) }
      )

      swap_index_concurrently!(
        target_name: FIXTURE_INDEX,
        tmp_name: FIXTURE_INDEX_TMP,
        columns: "organization_id, (test_workspace_manifest ->> 'demo_fixture_key')",
        where: "(demo = true OR COALESCE(test_workspace_purpose, '') = 'demo') AND COALESCE(test_workspace_manifest ->> 'demo_fixture_key', '') <> ''",
        matches_target: lambda { |definition|
          clause = where_clause(definition)
          (clause.match?(/\bdemo\s*=\s*true\b/i) || clause.match?(/\(\s*demo\s+OR\b/i)) &&
            clause.include?("demo_fixture_key")
        }
      )
    end
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM companies WHERE demo = TRUE)")
      raise ActiveRecord::IrreversibleMigration, "Convert or remove companies with demo = true before rolling back this migration"
    end

    with_session_lock_timeout do
      swap_index_concurrently!(
        target_name: FIXTURE_INDEX,
        tmp_name: FIXTURE_INDEX_TMP,
        columns: "organization_id, (test_workspace_manifest ->> 'demo_fixture_key')",
        where: "COALESCE(test_workspace_purpose, '') = 'demo'",
        matches_target: lambda { |definition|
          clause = where_clause(definition)
          !clause.match?(/\bdemo\s*=\s*true\b/i) &&
            !clause.match?(/\(\s*demo\s+OR\b/i) &&
            !clause.include?("demo_fixture_key")
        }
      )

      swap_index_concurrently!(
        target_name: EIN_INDEX,
        tmp_name: EIN_INDEX_TMP,
        columns: :ein,
        where: "payroll_environment = 'live'",
        matches_target: ->(definition) { !where_clause(definition).match?(/\bNOT\s+demo\b/i) }
      )
    end

    with_lock_timeout do
      remove_check_constraint :companies, name: DEMO_LIVE_CONSTRAINT, if_exists: true
      remove_column :companies, :demo, if_exists: true
    end
  end

  private

  def with_lock_timeout
    connection.transaction do
      execute "SET LOCAL lock_timeout = #{connection.quote(LOCK_TIMEOUT)}"
      yield
    end
  end

  # CONCURRENTLY operations and VALIDATE CONSTRAINT run outside a DDL
  # transaction, so SET LOCAL would have no effect. Apply a session-level
  # lock_timeout and always restore the prior value in ensure.
  def with_session_lock_timeout
    previous = select_value("SHOW lock_timeout")
    execute "SET lock_timeout = #{connection.quote(LOCK_TIMEOUT)}"
    yield
  ensure
    execute "SET lock_timeout = #{connection.quote(previous || '0')}"
  end

  def where_clause(definition)
    definition.to_s.split(/\bWHERE\b/i, 2)[1].to_s
  end

  def index_state(name)
    row = select_one(<<~SQL.squish)
      SELECT i.indisvalid AS valid,
             pg_get_indexdef(c.oid) AS definition
      FROM pg_class c
      JOIN pg_index i ON i.indexrelid = c.oid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = current_schema()
        AND c.relkind = 'i'
        AND c.relname = #{connection.quote(name)}
    SQL
    return nil unless row

    {
      valid: ActiveModel::Type::Boolean.new.cast(row["valid"]),
      definition: row["definition"].to_s
    }
  end

  def swap_index_concurrently!(target_name:, tmp_name:, columns:, where:, matches_target:)
    target = index_state(target_name)
    tmp = index_state(tmp_name)

    if target && target[:valid] && matches_target.call(target[:definition])
      remove_index :companies, name: tmp_name, algorithm: :concurrently, if_exists: true if tmp
      return
    end

    if tmp && (!tmp[:valid] || !matches_target.call(tmp[:definition]))
      remove_index :companies, name: tmp_name, algorithm: :concurrently, if_exists: true
      tmp = nil
    end

    if tmp.nil?
      add_index :companies, columns, unique: true, where: where, name: tmp_name, algorithm: :concurrently
      tmp = index_state(tmp_name)
    end

    unless tmp && tmp[:valid] && matches_target.call(tmp[:definition])
      raise ActiveRecord::MigrationError, "Replacement index #{tmp_name} is not valid; refusing to drop #{target_name}"
    end

    if target
      remove_index :companies, name: target_name, algorithm: :concurrently, if_exists: true
    end

    with_lock_timeout do
      execute "ALTER INDEX #{quote_table_name(tmp_name)} RENAME TO #{quote_table_name(target_name)}"
    end
  end
end
