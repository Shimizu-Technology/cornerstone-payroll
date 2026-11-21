# frozen_string_literal: true

# One sender can't hold the same numeric invoice number twice with and
# without leading zeros ("7055" and "07055"). Invoice validates this, but two
# saves at the same moment can both pass validation, so the database enforces
# it too. Scoped per billing profile, like the existing exact-number index
# (index_invoices_on_billing_profile_invoice_number). Only all-digit numbers
# are covered; drafts ("DRAFT-...") and prefixed numbers ("CS-2026-0001") are
# not.
class AddNormalizedInvoiceNumberIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_invoices_on_billing_profile_normalized_number"

  def up
    duplicates = select_rows(<<~SQL)
      SELECT invoice_billing_profile_id, string_agg(invoice_number || ' (invoice ' || id || ')', ', ' ORDER BY id)
      FROM invoices
      WHERE invoice_number ~ '^[0-9]+$'
      GROUP BY invoice_billing_profile_id, ltrim(invoice_number, '0')
      HAVING count(*) > 1
      ORDER BY invoice_billing_profile_id
    SQL
    if duplicates.any?
      details = duplicates.map { |profile_id, numbers| "billing profile #{profile_id}: #{numbers}" }.join("; ")
      raise "Can't add #{INDEX_NAME}: these invoices share a number once leading zeros are removed. " \
            "Renumber or remove one of each pair, then run the migration again. #{details}"
    end

    # A failed concurrent build leaves an INVALID index behind; drop it so a
    # rerun builds a real one instead of skipping it.
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{INDEX_NAME}") if invalid_index?
    add_index :invoices, "invoice_billing_profile_id, ltrim(invoice_number, '0')",
              unique: true, where: "invoice_number ~ '^[0-9]+$'", name: INDEX_NAME,
              algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :invoices, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end

  private

  def invalid_index?
    select_value(<<~SQL).present?
      SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = '#{INDEX_NAME}' AND NOT i.indisvalid
    SQL
  end
end
