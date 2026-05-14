# frozen_string_literal: true

# Re-scope printer profiles from individual users to the active organization.
#
# A printer calibration is usually shared by the staff in one accounting firm:
# same office, same check stock, same printer trays. Organization scoping keeps
# those profiles available to every admin/operator in the tenant without leaking
# them across firms.
class ScopePrinterProfilesToOrganization < ActiveRecord::Migration[8.0]
  def up
    add_reference :printer_profiles, :organization, foreign_key: true, index: true

    execute <<~SQL.squish
      UPDATE printer_profiles pp
         SET organization_id = users.organization_id
        FROM users
       WHERE users.id = pp.user_id
    SQL

    execute "DELETE FROM printer_profiles WHERE organization_id IS NULL"
    change_column_null :printer_profiles, :organization_id, false

    dedupe_names_for_organization_scope!
    dedupe_defaults_for_organization_scope!

    if index_exists?(:printer_profiles, [:user_id, :name], name: "index_printer_profiles_on_user_id_and_name")
      remove_index :printer_profiles, name: "index_printer_profiles_on_user_id_and_name"
    end
    if index_exists?(:printer_profiles, :user_id, name: "index_printer_profiles_one_default_per_user")
      remove_index :printer_profiles, name: "index_printer_profiles_one_default_per_user"
    end
    if foreign_key_exists?(:printer_profiles, :users)
      remove_foreign_key :printer_profiles, :users
    end
    remove_column :printer_profiles, :user_id

    add_index :printer_profiles, [:organization_id, :name], unique: true,
      name: "index_printer_profiles_on_organization_id_and_name"
    add_index :printer_profiles, :organization_id, unique: true,
      where: "is_default = TRUE",
      name: "index_printer_profiles_one_default_per_organization"
  end

  def down
    add_reference :printer_profiles, :user, foreign_key: true, index: true

    execute <<~SQL.squish
      UPDATE printer_profiles pp
         SET user_id = users.id
        FROM (
          SELECT DISTINCT ON (organization_id) id, organization_id
            FROM users
           WHERE active = TRUE
        ORDER BY organization_id, id ASC
        ) users
       WHERE users.organization_id = pp.organization_id
    SQL

    execute <<~SQL.squish
      UPDATE printer_profiles pp
         SET user_id = users.id
        FROM (
          SELECT DISTINCT ON (organization_id) id, organization_id
            FROM users
        ORDER BY organization_id, id ASC
        ) users
       WHERE users.organization_id = pp.organization_id
         AND pp.user_id IS NULL
    SQL

    execute "DELETE FROM printer_profiles WHERE user_id IS NULL"
    change_column_null :printer_profiles, :user_id, false

    dedupe_names_for_user_scope!
    dedupe_defaults_for_user_scope!

    if index_exists?(:printer_profiles, [:organization_id, :name], name: "index_printer_profiles_on_organization_id_and_name")
      remove_index :printer_profiles, name: "index_printer_profiles_on_organization_id_and_name"
    end
    if index_exists?(:printer_profiles, :organization_id, name: "index_printer_profiles_one_default_per_organization")
      remove_index :printer_profiles, name: "index_printer_profiles_one_default_per_organization"
    end
    if foreign_key_exists?(:printer_profiles, :organizations)
      remove_foreign_key :printer_profiles, :organizations
    end
    remove_column :printer_profiles, :organization_id

    add_index :printer_profiles, [:user_id, :name], unique: true,
      name: "index_printer_profiles_on_user_id_and_name"
    add_index :printer_profiles, :user_id, unique: true,
      where: "is_default = TRUE",
      name: "index_printer_profiles_one_default_per_user"
  end

  private

  def dedupe_names_for_organization_scope!
    execute <<~SQL.squish
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY organization_id, name
                 ORDER BY id ASC
               ) AS duplicate_number
          FROM printer_profiles
      )
      UPDATE printer_profiles pp
         SET name = CONCAT(pp.name, ' (', pp.id, ')')
        FROM ranked
       WHERE ranked.id = pp.id
         AND ranked.duplicate_number > 1
    SQL
  end

  def dedupe_defaults_for_organization_scope!
    execute <<~SQL.squish
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY organization_id
                 ORDER BY updated_at DESC, id ASC
               ) AS default_number
          FROM printer_profiles
         WHERE is_default = TRUE
      )
      UPDATE printer_profiles pp
         SET is_default = FALSE
        FROM ranked
       WHERE ranked.id = pp.id
         AND ranked.default_number > 1
    SQL
  end

  def dedupe_names_for_user_scope!
    execute <<~SQL.squish
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY user_id, name
                 ORDER BY id ASC
               ) AS duplicate_number
          FROM printer_profiles
      )
      UPDATE printer_profiles pp
         SET name = CONCAT(pp.name, ' (', pp.id, ')')
        FROM ranked
       WHERE ranked.id = pp.id
         AND ranked.duplicate_number > 1
    SQL
  end

  def dedupe_defaults_for_user_scope!
    execute <<~SQL.squish
      WITH ranked AS (
        SELECT id,
               ROW_NUMBER() OVER (
                 PARTITION BY user_id
                 ORDER BY updated_at DESC, id ASC
               ) AS default_number
          FROM printer_profiles
         WHERE is_default = TRUE
      )
      UPDATE printer_profiles pp
         SET is_default = FALSE
        FROM ranked
       WHERE ranked.id = pp.id
         AND ranked.default_number > 1
    SQL
  end
end
