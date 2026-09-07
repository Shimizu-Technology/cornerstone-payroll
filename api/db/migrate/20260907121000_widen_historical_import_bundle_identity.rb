# frozen_string_literal: true

class WidenHistoricalImportBundleIdentity < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    remove_invalid_index("idx_historical_batches_unique_bundle_version")
    add_index :historical_import_batches,
              %i[company_id source_system bundle_digest importer_version],
              unique: true,
              name: "idx_historical_batches_unique_bundle_version",
              algorithm: :concurrently,
              if_not_exists: true
    remove_index :historical_import_batches,
                 name: "idx_historical_batches_unique_bundle",
                 algorithm: :concurrently,
                 if_exists: true
    validate_check_constraint :historical_import_batches,
                              name: "historical_import_batches_tax_wage_object"
  end

  def down
    duplicate_count = select_value(<<~SQL.squish).to_i
      SELECT COUNT(*)
      FROM (
        SELECT 1
        FROM historical_import_batches
        GROUP BY company_id, source_system, bundle_digest
        HAVING COUNT(*) > 1
      ) duplicated_bundles
    SQL
    if duplicate_count.positive?
      raise ActiveRecord::IrreversibleMigration,
            "#{duplicate_count} bundle(s) exist under more than one importer version; resolve them before rolling back"
    end

    remove_invalid_index("idx_historical_batches_unique_bundle")
    add_index :historical_import_batches,
              %i[company_id source_system bundle_digest],
              unique: true,
              name: "idx_historical_batches_unique_bundle",
              algorithm: :concurrently,
              if_not_exists: true
    remove_index :historical_import_batches,
                 name: "idx_historical_batches_unique_bundle_version",
                 algorithm: :concurrently,
                 if_exists: true
  end

  private

  # Remove an invalid index left behind by an interrupted CREATE INDEX CONCURRENTLY.
  def remove_invalid_index(name)
    invalid = select_value(<<~SQL.squish)
      SELECT EXISTS (
        SELECT 1
        FROM pg_index indexes
        JOIN pg_class index_names ON index_names.oid = indexes.indexrelid
        JOIN pg_namespace namespaces ON namespaces.oid = index_names.relnamespace
        WHERE namespaces.nspname = current_schema()
          AND index_names.relname = #{connection.quote(name)}
          AND NOT indexes.indisvalid
      )
    SQL
    return unless invalid == true || invalid.to_s == "t"

    remove_index :historical_import_batches,
                 name: name,
                 algorithm: :concurrently,
                 if_exists: true
  end
end
