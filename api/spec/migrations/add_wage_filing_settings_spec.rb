# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261120080000_add_wage_filing_settings")

RSpec.describe AddWageFilingSettings do
  it "reapplies to populated client tables with safe defaults and preserves client/employee identities" do
    company = create(:company)
    employee = create(:employee, company: company)
    migration = described_class.new.tap { |instance| instance.verbose = false }
    migration.migrate(:down)
    migration.migrate(:up)
    [ Company, Employee, FilingSubmitter ].each(&:reset_column_information)
    expect(company.reload.kind_of_employer).to eq("N")
    expect(company.employment_code).to eq("R")
    expect(employee.reload.company_id).to eq(company.id)
    expect(employee.name_suffix).to be_nil
    FilingSubmitter.create!(organization: company.organization)
    expect(FilingSubmitter.where(organization: company.organization).count).to eq(1)
  ensure
    [ Company, Employee, FilingSubmitter ].each(&:reset_column_information)
  end
end
