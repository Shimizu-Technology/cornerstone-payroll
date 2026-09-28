# frozen_string_literal: true

class CreateFinanceBooks < ActiveRecord::Migration[8.1]
  class MigrationOrganization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class MigrationFinanceBook < ActiveRecord::Base
    self.table_name = "finance_books"
  end

  def up
    create_table :finance_books do |table|
      table.references :organization, null: false, foreign_key: { on_delete: :cascade }
      table.references :company, foreign_key: true, index: false
      table.string :name, null: false
      table.string :legal_name, null: false
      table.string :kind, null: false, default: "organization"
      table.boolean :is_default, null: false, default: false
      table.boolean :active, null: false, default: true
      table.timestamps
    end
    add_index :finance_books, [ :organization_id, :name ], unique: true
    add_index :finance_books, [ :organization_id, :is_default ], unique: true,
              where: "is_default = true", name: "index_finance_books_one_default_per_organization"
    add_index :finance_books, :company_id, unique: true, where: "company_id IS NOT NULL"
    add_check_constraint :finance_books, "kind IN ('organization', 'client')", name: "finance_books_kind_check"
    add_check_constraint :finance_books,
                         "kind = 'organization' OR company_id IS NOT NULL",
                         name: "finance_books_client_has_company"

    MigrationOrganization.find_each do |organization|
      MigrationFinanceBook.create!(organization_id: organization.id, name: organization.name,
                                   legal_name: organization.name, kind: "organization", is_default: true)
    end
  end

  def down
    drop_table :finance_books
  end
end
