# frozen_string_literal: true

require "rails_helper"

require Rails.root.join("db/migrate/20261124120000_add_contact_details_tracking_to_employees")
require Rails.root.join("db/migrate/20261124120100_index_employees_on_lower_email")
require Rails.root.join("db/migrate/20261124120200_validate_employee_contact_source_constraint")
require Rails.root.join("db/migrate/20261124120300_create_employee_placeholder_emails")

RSpec.describe "M4-3 contact details split migrations" do
  it "keeps nullable column additions + NOT VALID constraint, concurrent index, and constraint validation in separate migrations" do
    column_source = File.read(Rails.root.join("db/migrate/20261124120000_add_contact_details_tracking_to_employees.rb"))
    expect(column_source).to include("validate: false")
    expect(column_source).not_to include("add_index")

    expect(IndexEmployeesOnLowerEmail.disable_ddl_transaction).to be(true)
    index_source = File.read(Rails.root.join("db/migrate/20261124120100_index_employees_on_lower_email.rb"))
    expect(index_source).to include("algorithm: :concurrently")

    validate_source = File.read(Rails.root.join("db/migrate/20261124120200_validate_employee_contact_source_constraint.rb"))
    expect(validate_source).to include("validate_check_constraint :employees, name: \"employees_contact_source_check\"")
  end

  it "has the validated check constraint, functional email index, and employee_placeholder_emails table present in the database" do
    connection = ActiveRecord::Base.connection

    constraints = connection.check_constraints(:employees)
    contact_source_check = constraints.find { |c| c.name == "employees_contact_source_check" }
    expect(contact_source_check).to be_present
    expect(contact_source_check.validated?).to be(true)

    indexes = connection.indexes(:employees)
    expect(indexes.map(&:name)).to include("index_employees_on_lower_email")

    expect(connection.table_exists?(:employee_placeholder_emails)).to be(true)
    placeholder_indexes = connection.indexes(:employee_placeholder_emails)
    expect(placeholder_indexes.any? { |idx| idx.name == "idx_employee_placeholder_emails_org_email" && idx.unique }).to be(true)
  end
end
