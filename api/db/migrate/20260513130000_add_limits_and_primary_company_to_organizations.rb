# frozen_string_literal: true

class AddLimitsAndPrimaryCompanyToOrganizations < ActiveRecord::Migration[8.1]
  class MigrationOrganization < ActiveRecord::Base
    self.table_name = "organizations"
  end

  class MigrationCompany < ActiveRecord::Base
    self.table_name = "companies"
  end

  def up
    add_column :organizations, :client_limit, :integer, default: 3
    add_reference :organizations, :primary_company, foreign_key: { to_table: :companies }

    single_existing_organization = MigrationOrganization.count == 1
    MigrationOrganization.find_each do |organization|
      first_company_id = MigrationCompany.where(organization_id: organization.id).order(:id).pick(:id)
      platform_org = single_existing_organization || organization.slug == "cornerstone-tax-services"
      client_limit = platform_org ? nil : 3
      organization.update_columns(primary_company_id: first_company_id, client_limit: client_limit)
    end
  end

  def down
    remove_reference :organizations, :primary_company, foreign_key: { to_table: :companies }
    remove_column :organizations, :client_limit
  end
end
