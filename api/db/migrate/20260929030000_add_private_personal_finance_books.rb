# frozen_string_literal: true

class AddPrivatePersonalFinanceBooks < ActiveRecord::Migration[8.1]
  def up
    add_reference :finance_books, :owner_user, foreign_key: { to_table: :users }, index: true
    remove_check_constraint :finance_books, name: "finance_books_kind_check"
    remove_check_constraint :finance_books, name: "finance_books_client_has_company"
    add_check_constraint :finance_books, "kind IN ('organization', 'client', 'personal')", name: "finance_books_kind_check"
    add_check_constraint :finance_books,
                         "(kind = 'client' AND company_id IS NOT NULL AND owner_user_id IS NULL) OR " \
                         "(kind = 'organization' AND owner_user_id IS NULL) OR " \
                         "(kind = 'personal' AND company_id IS NULL AND owner_user_id IS NOT NULL AND is_default = false)",
                         name: "finance_books_owner_shape_check"
    add_index :finance_books, [ :organization_id, :owner_user_id ], unique: true,
              where: "kind = 'personal'", name: "index_finance_books_one_personal_per_user"
    remove_index :finance_books, [ :organization_id, :name ]
    add_index :finance_books, [ :organization_id, :name ], unique: true,
              where: "kind <> 'personal'", name: "index_finance_books_on_organization_id_and_name"
  end

  def down
    if select_value("SELECT 1 FROM finance_books WHERE kind = 'personal' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "Move or remove personal book data before reverting this migration"
    end

    remove_index :finance_books, name: "index_finance_books_on_organization_id_and_name"
    add_index :finance_books, [ :organization_id, :name ], unique: true
    remove_index :finance_books, name: "index_finance_books_one_personal_per_user"
    remove_check_constraint :finance_books, name: "finance_books_owner_shape_check"
    remove_check_constraint :finance_books, name: "finance_books_kind_check"
    add_check_constraint :finance_books, "kind IN ('organization', 'client')", name: "finance_books_kind_check"
    add_check_constraint :finance_books, "kind = 'organization' OR company_id IS NOT NULL", name: "finance_books_client_has_company"
    remove_reference :finance_books, :owner_user, foreign_key: { to_table: :users }, index: true
  end
end
