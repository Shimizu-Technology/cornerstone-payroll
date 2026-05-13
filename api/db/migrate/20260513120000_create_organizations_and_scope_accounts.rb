# frozen_string_literal: true

class CreateOrganizationsAndScopeAccounts < ActiveRecord::Migration[8.1]
  DEFAULT_ORGANIZATION_NAME = "Cornerstone Tax Services"
  DEFAULT_ORGANIZATION_SLUG = "cornerstone-tax-services"

  class MigrationOrganization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class MigrationCompany < ActiveRecord::Base
    self.table_name = "companies"
  end

  class MigrationUser < ActiveRecord::Base
    self.table_name = "users"
  end

  def up
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.string :status, null: false, default: "active"

      t.timestamps
    end

    add_index :organizations, :slug, unique: true
    add_index :organizations, :status

    add_reference :companies, :organization, foreign_key: true
    add_reference :users, :organization, foreign_key: true

    default_org = MigrationOrganization.create!(
      name: DEFAULT_ORGANIZATION_NAME,
      slug: DEFAULT_ORGANIZATION_SLUG,
      status: "active",
      created_at: Time.current,
      updated_at: Time.current
    )

    MigrationCompany.update_all(organization_id: default_org.id)

    MigrationUser.find_each do |user|
      company_org_id = MigrationCompany.where(id: user.company_id).pick(:organization_id)
      user.update_columns(organization_id: company_org_id || default_org.id)
    end

    change_column_null :companies, :organization_id, false
    change_column_null :users, :organization_id, false
  end

  def down
    remove_reference :users, :organization, foreign_key: true
    remove_reference :companies, :organization, foreign_key: true
    drop_table :organizations
  end
end
