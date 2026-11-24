# frozen_string_literal: true

# M4-9a: a client's uploaded employee-app logo and its Help contacts.
#
# The logo bytes live in R2. The company row keeps only the storage key and a
# fingerprint, so the public branding response can build a content-addressed
# URL without exposing the key.
#
# Help contacts are company-scoped and only ever served to signed-in
# employees, so the table is RLS-protected from this first migration. The
# policy is staged (created, not enabled or forced), like every other
# protected table until M3-7 phase 3.
class AddEmployeeAppBrandingAndHelpContacts < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"

    add_column :companies, :brand_logo_storage_key, :string
    add_column :companies, :brand_logo_content_type, :string
    add_column :companies, :brand_logo_sha256, :string
    add_column :companies, :brand_logo_byte_size, :integer
    add_check_constraint :companies, <<~SQL.squish, name: "company_brand_logo_shape"
      num_nonnulls(brand_logo_storage_key, brand_logo_content_type, brand_logo_sha256, brand_logo_byte_size) IN (0, 4)
      AND (brand_logo_content_type IS NULL OR brand_logo_content_type IN ('image/png', 'image/webp'))
      AND (brand_logo_sha256 IS NULL OR brand_logo_sha256 ~ '^[0-9a-f]{64}$')
    SQL

    create_table :company_help_contacts do |t|
      t.references :company, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.integer :position, null: false
      t.string :name, null: false
      t.string :role
      t.string :phone
      t.string :email
      t.boolean :text_ok, null: false, default: false
      t.timestamps

      t.index %i[company_id position], unique: true
      t.check_constraint "position BETWEEN 1 AND 5", name: "company_help_contact_position_range"
      t.check_constraint "char_length(btrim(name)) BETWEEN 1 AND 80", name: "company_help_contact_name_length"
      t.check_constraint "num_nonnulls(phone, email) >= 1", name: "company_help_contact_reachable"
      t.check_constraint "NOT text_ok OR phone IS NOT NULL", name: "company_help_contact_text_needs_phone"
    end

    stage_company_policy("company_help_contacts")
  end

  def down
    execute "SET LOCAL lock_timeout = '5s'"
    drop_table :company_help_contacts
    remove_check_constraint :companies, name: "company_brand_logo_shape"
    remove_column :companies, :brand_logo_byte_size
    remove_column :companies, :brand_logo_sha256
    remove_column :companies, :brand_logo_content_type
    remove_column :companies, :brand_logo_storage_key
  end

  private

  # The same policy RlsDatabase.install! creates. A database that hasn't had
  # the installer run yet gets it from the next `rls:install` or schema load.
  def stage_company_policy(table)
    return unless select_value("SELECT to_regprocedure('app_current_company_id()') IS NOT NULL")

    quoted = quote_table_name(table)
    execute "DROP POLICY IF EXISTS company_isolation ON #{quoted}"
    execute <<~SQL.squish
      CREATE POLICY company_isolation ON #{quoted}
      USING (current_setting('app.rls_mode', true) = 'system' OR (company_id = app_current_company_id()))
      WITH CHECK (current_setting('app.rls_mode', true) = 'system' OR (company_id = app_current_company_id()))
    SQL
  end
end
