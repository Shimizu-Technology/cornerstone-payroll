# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261009010100_expand_employee_w4_election_sources")

RSpec.describe ExpandEmployeeW4ElectionSources do
  self.use_transactional_tests = false

  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }
  let(:table) { :intake_source_constraint_probe }

  before do
    stub_const("ExpandEmployeeW4ElectionSources::TABLE", table)
    connection.create_table(table) { |t| t.string :source, null: false }
    connection.add_check_constraint(table, "source IN ('staff', 'client_approved', 'employee_creation', 'legacy_profile', 'quickbooks_history')",
      name: described_class::CONSTRAINT)
  end

  after do
    connection.drop_table(table, if_exists: true)
  end

  def insert_source(source)
    connection.execute("INSERT INTO intake_source_constraint_probe (source) VALUES (#{connection.quote(source)})")
  end

  it "keeps original sources enforced during validation and swaps only a validated constraint" do
    insert_source("staff")
    allow(migration).to receive(:validate_check_constraint).and_wrap_original do |method, *args, **kwargs|
      expect(connection.check_constraint_exists?(table, name: described_class::CONSTRAINT)).to be true
      expect { insert_source("default_withholding") }.to raise_error(ActiveRecord::StatementInvalid)
      method.call(*args, **kwargs)
    end
    migration.up
    expect(connection.check_constraints(table).map(&:name)).to eq([ described_class::CONSTRAINT ])
    constraint = connection.check_constraints(table).first
    expect(constraint).to be_validate
    insert_source("default_withholding")
    expect { insert_source("invented_source") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "resumes an interrupted temporary constraint and is idempotent after swapping" do
    connection.add_check_constraint(table, "source IN ('staff', 'client_approved', 'employee_creation', 'legacy_profile', 'quickbooks_history', 'default_withholding')",
      name: "employee_w4_elections_source_expanded_check", validate: false)
    2.times { migration.up }
    expect(connection.check_constraints(table).map(&:name)).to eq([ described_class::CONSTRAINT ])
    insert_source("default_withholding")
  end

  it "cleans a known interrupted rollback restriction when resuming the expanded schema" do
    migration.up
    connection.add_check_constraint(table, "source IN ('staff', 'client_approved', 'employee_creation', 'legacy_profile', 'quickbooks_history')",
      name: "employee_w4_elections_source_original_check", validate: false)
    migration.up
    expect(connection.check_constraints(table).map(&:name)).to eq([ described_class::CONSTRAINT ])
    insert_source("default_withholding")
  end

  it "rolls back and reapplies without a missing constraint" do
    migration.up
    migration.down
    expect { insert_source("default_withholding") }.to raise_error(ActiveRecord::StatementInvalid)
    insert_source("staff")
    migration.up
    insert_source("default_withholding")
  end

  it "refuses to discard existing default rows during rollback and removes the failed narrower temporary restriction" do
    migration.up
    insert_source("default_withholding")
    expect { migration.down }.to raise_error(ActiveRecord::StatementInvalid)
    expect(connection.select_value("SELECT count(*) FROM intake_source_constraint_probe")).to eq(1)
    expect(connection.check_constraints(table).map(&:name)).to eq([ described_class::CONSTRAINT ])
    insert_source("default_withholding")
  end
end
