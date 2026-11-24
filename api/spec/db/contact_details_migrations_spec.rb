# frozen_string_literal: true

require "rails_helper"

require Rails.root.join("db/migrate/20261124120000_add_contact_details_tracking_to_employees")
require Rails.root.join("db/migrate/20261124120100_index_employees_on_lower_email")
require Rails.root.join("db/migrate/20261124120200_validate_employee_contact_source_constraint")
require Rails.root.join("db/migrate/20261124120300_create_employee_placeholder_emails")

RSpec.describe "M4-3 contact details split migrations" do
  it "keeps nullable column additions + NOT VALID constraint with lock_timeout, concurrent index with invalid-index repair, and constraint validation in separate migrations" do
    column_source = File.read(Rails.root.join("db/migrate/20261124120000_add_contact_details_tracking_to_employees.rb"))
    expect(column_source).to include("SET LOCAL lock_timeout = '5s'")
    expect(column_source).to include("validate: false")
    expect(column_source).not_to include("add_index")

    expect(IndexEmployeesOnLowerEmail.disable_ddl_transaction).to be(true)
    index_source = File.read(Rails.root.join("db/migrate/20261124120100_index_employees_on_lower_email.rb"))
    expect(index_source).to include("algorithm: :concurrently")
    expect(index_source).to include("indisvalid")

    validate_source = File.read(Rails.root.join("db/migrate/20261124120200_validate_employee_contact_source_constraint.rb"))
    expect(validate_source).to include("SET LOCAL lock_timeout = '5s'")
    expect(validate_source).to include("validate_check_constraint :employees, name: \"employees_contact_source_check\"")
  end

  it "drops and rebuilds an invalid concurrent index on retry instead of skipping it" do
    migration = IndexEmployeesOnLowerEmail.new
    allow(migration).to receive(:invalid_index?).and_return(true)
    expect(migration).to receive(:remove_index).with(
      :employees,
      name: IndexEmployeesOnLowerEmail::INDEX_NAME,
      algorithm: :concurrently
    ).ordered
    expect(migration).to receive(:add_index).with(
      :employees,
      IndexEmployeesOnLowerEmail::EXPRESSION,
      name: IndexEmployeesOnLowerEmail::INDEX_NAME,
      where: "email IS NOT NULL",
      algorithm: :concurrently,
      if_not_exists: true
    ).ordered

    migration.up
  end

  it "has the validated check constraint, functional email index, and employee_placeholder_emails table present in the database" do
    connection = ActiveRecord::Base.connection

    constraints = connection.check_constraints(:employees)
    contact_source_check = constraints.find { |c| c.name == "employees_contact_source_check" }
    expect(contact_source_check).to be_present
    expect(contact_source_check.validated?).to be(true)

    email_index = connection.indexes(:employees).find { |idx| idx.name == "index_employees_on_lower_email" }
    expect(email_index).to be_present
    expect(email_index.where).to eq("(email IS NOT NULL)")
    expect(email_index.columns).to eq("lower(btrim((email)::text, ' \t\n\v\f\r'::text))")
    expect(connection.select_value(<<~SQL)).to be(true)
      SELECT i.indisvalid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
      WHERE c.relname = 'index_employees_on_lower_email'
    SQL

    # The lookup expression the app uses is the indexed one.
    plan = connection.transaction do
      connection.execute("SET LOCAL enable_seqscan = off")
      sql = Employee.where("#{EmployeeContactValidator.normalized_email_sql} = ?", "a@example.com").where.not(email: nil).to_sql
      connection.select_values("EXPLAIN #{sql}").join("\n")
    end
    expect(plan).to include("index_employees_on_lower_email")

    expect(connection.table_exists?(:employee_placeholder_emails)).to be(true)
    placeholder_indexes = connection.indexes(:employee_placeholder_emails)
    expect(placeholder_indexes.any? { |idx| idx.name == "idx_employee_placeholder_emails_org_email" && idx.unique }).to be(true)
  end
end
