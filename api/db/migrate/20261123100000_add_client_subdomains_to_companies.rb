# frozen_string_literal: true

class AddClientSubdomainsToCompanies < ActiveRecord::Migration[8.1]
  def change
    add_column :companies, :subdomain_slug, :string
    add_column :companies, :branding, :jsonb, default: {}, null: false

    add_index :companies, "lower(subdomain_slug)",
              unique: true, where: "payroll_environment = 'live' AND subdomain_slug IS NOT NULL",
              name: "index_live_companies_on_lower_subdomain_slug"
    add_check_constraint :companies, "subdomain_slug IS NULL OR payroll_environment = 'live'",
                         name: "company_subdomain_requires_live_payroll"
  end
end
