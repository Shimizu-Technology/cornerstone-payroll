# frozen_string_literal: true

class AddTaxConfigurationVerification < ActiveRecord::Migration[8.1]
  def up
    add_column :annual_tax_configs, :verification_status, :string, null: false, default: "draft"
    add_column :annual_tax_configs, :verified_by, :string
    add_column :annual_tax_configs, :verified_at, :datetime
    add_column :annual_tax_configs, :source_references, :text
    add_check_constraint :annual_tax_configs, "verification_status IN ('draft', 'verified')", name: "annual_tax_verification_status"
    # Retain pre-existing rules byte-for-byte, including inactive historical rules.
    execute <<~SQL
      UPDATE annual_tax_configs SET verification_status = 'verified',
        verified_by = 'migration:20261024093000', verified_at = CURRENT_TIMESTAMP,
        source_references = 'Existing tax configuration through 2026; grandfathered without changing tax values.'
      WHERE tax_year <= 2026
    SQL
    # The legacy engine is still used for retained pre-2027 payroll. New legacy
    # rows are drafts; it cannot provide a back door around an annual draft.
    add_column :tax_tables, :verification_status, :string, null: false, default: "draft"
    add_check_constraint :tax_tables, "verification_status IN ('draft', 'verified')", name: "legacy_tax_verification_status"
    execute "UPDATE tax_tables SET verification_status = 'verified' WHERE tax_year <= 2026"
  end

  def down
    remove_check_constraint :tax_tables, name: "legacy_tax_verification_status"
    remove_column :tax_tables, :verification_status
    remove_check_constraint :annual_tax_configs, name: "annual_tax_verification_status"
    remove_column :annual_tax_configs, :source_references
    remove_column :annual_tax_configs, :verified_at
    remove_column :annual_tax_configs, :verified_by
    remove_column :annual_tax_configs, :verification_status
  end
end
