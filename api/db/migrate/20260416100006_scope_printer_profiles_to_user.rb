# frozen_string_literal: true

# Re-scope printer profiles from per-company to per-user.
#
# Background: A printer profile (X/Y offset, stock type, layout overrides,
# notes) describes a physical printer that an operator owns. Operators
# routinely run payroll for several client companies on the same printer, so
# it makes no sense to force them to recreate the same profile under each
# client. Scoping by user lets the same alignment settings follow the user
# wherever they go.
#
# Migration is destructive in the sense that we drop `company_id`, but every
# existing profile is preserved and re-attached to a real user (the first
# admin of the originating company, falling back to any user of that
# company, then any admin in the system, then any user). If no users exist
# at all the row is deleted, since a user-scoped profile with no user is
# meaningless.
class ScopePrinterProfilesToUser < ActiveRecord::Migration[8.0]
  def up
    add_reference :printer_profiles, :user, foreign_key: true, index: true

    # Backfill user_id by picking a sensible owner per existing profile.
    backfill_user_ids!

    # Drop any rows we couldn't attach (no users exist anywhere) — they
    # would violate the new not-null constraint and serve no purpose.
    execute "DELETE FROM printer_profiles WHERE user_id IS NULL"

    change_column_null :printer_profiles, :user_id, false

    # Old indexes / fk are scoped to company — replace with user-scoped ones.
    if index_exists?(:printer_profiles, [:company_id, :name], name: "index_printer_profiles_on_company_id_and_name")
      remove_index :printer_profiles, name: "index_printer_profiles_on_company_id_and_name"
    end
    if index_exists?(:printer_profiles, :company_id, name: "index_printer_profiles_one_default_per_company")
      remove_index :printer_profiles, name: "index_printer_profiles_one_default_per_company"
    end
    if foreign_key_exists?(:printer_profiles, :companies)
      remove_foreign_key :printer_profiles, :companies
    end
    remove_column :printer_profiles, :company_id

    add_index :printer_profiles, [:user_id, :name], unique: true,
              name: "index_printer_profiles_on_user_id_and_name"
    add_index :printer_profiles, :user_id, unique: true,
              where: "is_default = TRUE",
              name: "index_printer_profiles_one_default_per_user"
  end

  def down
    # Best-effort rollback: re-introduce company_id and try to re-attach via
    # the user's home company. New profiles created since the up migration
    # will fall back to the owning user's company.
    add_reference :printer_profiles, :company, foreign_key: true, index: true

    execute <<~SQL.squish
      UPDATE printer_profiles pp
         SET company_id = u.company_id
        FROM users u
       WHERE u.id = pp.user_id
    SQL

    execute "DELETE FROM printer_profiles WHERE company_id IS NULL"
    change_column_null :printer_profiles, :company_id, false

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

    add_index :printer_profiles, [:company_id, :name], unique: true,
              name: "index_printer_profiles_on_company_id_and_name"
    add_index :printer_profiles, :company_id, unique: true,
              where: "is_default = TRUE",
              name: "index_printer_profiles_one_default_per_company"
  end

  private

  def backfill_user_ids!
    # 1. Try the first admin user of the profile's existing company.
    #    role = 0 corresponds to the :admin enum value on User.
    execute <<~SQL.squish
      UPDATE printer_profiles pp
         SET user_id = sub.id
        FROM (
          SELECT DISTINCT ON (company_id) id, company_id
            FROM users
           WHERE role = 0
             AND active = TRUE
        ORDER BY company_id, id ASC
        ) AS sub
       WHERE sub.company_id = pp.company_id
         AND pp.user_id IS NULL
    SQL

    # 2. Any active user of that company.
    execute <<~SQL.squish
      UPDATE printer_profiles pp
         SET user_id = sub.id
        FROM (
          SELECT DISTINCT ON (company_id) id, company_id
            FROM users
           WHERE active = TRUE
        ORDER BY company_id, id ASC
        ) AS sub
       WHERE sub.company_id = pp.company_id
         AND pp.user_id IS NULL
    SQL

    # 3. Any admin anywhere (in case the company has no users at all).
    #    role = 0 == :admin enum.
    fallback_admin_id = select_value(
      "SELECT id FROM users WHERE role = 0 AND active = TRUE ORDER BY id ASC LIMIT 1"
    )
    if fallback_admin_id
      execute "UPDATE printer_profiles SET user_id = #{fallback_admin_id} WHERE user_id IS NULL"
    end

    # 4. Any user at all.
    fallback_any_id = select_value("SELECT id FROM users ORDER BY id ASC LIMIT 1")
    if fallback_any_id
      execute "UPDATE printer_profiles SET user_id = #{fallback_any_id} WHERE user_id IS NULL"
    end
  end
end
