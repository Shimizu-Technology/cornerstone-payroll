# frozen_string_literal: true

# M4-9d: the server-side record of the Employee App Terms of Use and Privacy
# Notice version, so the switch can check counsel's status (draft or
# approved) before a terms screen is shown. Rows are immutable; counsel's
# approval inserts a new approved version.
class CreateEmployeeTermsVersions < ActiveRecord::Migration[8.1]
  def up
    create_table :employee_terms_versions do |t|
      t.string :version, null: false, limit: 80
      t.string :status, null: false, default: "draft", limit: 20
      t.string :terms_url, null: false, limit: 500
      t.string :privacy_url, null: false, limit: 500
      t.datetime :published_at, null: false
      t.timestamps null: false

      t.index :version, unique: true, name: "idx_employee_terms_versions_version"
      t.index %i[status published_at id], name: "idx_employee_terms_versions_current"
      t.check_constraint "status IN ('draft', 'approved')", name: "employee_terms_versions_status_check"
    end

    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_employee_terms_version_mutation() RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'employee_terms_versions rows are immutable; insert a new version instead'
          USING ERRCODE = 'check_violation';
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS employee_terms_versions_immutable ON employee_terms_versions;
      CREATE TRIGGER employee_terms_versions_immutable
      BEFORE UPDATE OR DELETE ON employee_terms_versions
      FOR EACH ROW
      EXECUTE FUNCTION prevent_employee_terms_version_mutation();
    SQL
  end

  def down
    drop_table :employee_terms_versions
    execute "DROP FUNCTION IF EXISTS prevent_employee_terms_version_mutation()"
  end
end
