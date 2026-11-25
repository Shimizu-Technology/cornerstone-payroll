# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261123150200_constrain_payroll_child_companies")

RSpec.describe PayrollChildCompanyBackfill do
  let(:connection) { ApplicationRecord.connection }
  let(:payroll_item) { create(:payroll_item) }
  let(:event_attributes) do
    { payroll_item_id: payroll_item.id, event_type: "printed", check_number: "100", effective_on: Date.current }
  end

  # Legacy rows predate the expand migration. The contract migration has
  # since required company_id, so rebuild that state inside the example.
  def allow_legacy_null_company!
    connection.execute("ALTER TABLE check_events DISABLE TRIGGER fill_check_events_company_id")
    connection.change_column_null :check_events, :company_id, true
  end

  it "fills an omitted company ID from the parent for old bulk inserts" do
    result = CheckEvent.insert_all!([ event_attributes, event_attributes ], returning: %w[company_id])
    expect(result.rows.flatten).to eq([ payroll_item.company_id, payroll_item.company_id ])
  end

  it "rejects a supplied company ID that does not own the parent" do
    other_company = create(:company)
    expect do
      connection.transaction(requires_new: true) do
        CheckEvent.insert_all!([ event_attributes.merge(company_id: other_company.id) ])
      end
    end.to raise_error(ActiveRecord::InvalidForeignKey, /fk_check_events_company_parent/)
  end

  it "backfills legacy evidence in batches, preserving its fields and rejecting later edits" do
    allow_legacy_null_company!
    ids = CheckEvent.insert_all!([ event_attributes, event_attributes ], returning: %w[id]).rows.flatten
    events = CheckEvent.where(id: ids).order(:id)
    original = events.map { |row| row.attributes.except("company_id") }

    expect(events.pluck(:company_id)).to eq([ nil, nil ])
    expect do
      connection.transaction(requires_new: true) do
        events.update_all(company_id: payroll_item.company_id, reason: "changed evidence")
      end
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)

    backfill = described_class.new(connection: connection, batch_size: 1)
    first_pass = {}
    backfill.backfill { |table, count| first_pass[table] = count }
    expect(first_pass.fetch(:check_events)).to eq(2)
    expect(events.reload.pluck(:company_id)).to all(eq(payroll_item.company_id))
    expect(events.map { |row| row.attributes.except("company_id") }).to eq(original)

    second_pass = {}
    backfill.backfill { |table, count| second_pass[table] = count }
    expect(second_pass.values).to all(eq(0))
    expect do
      connection.transaction(requires_new: true) { events.update_all(company_id: nil) }
    end.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
  end

  it "accepts only batch sizes within the configured bounds" do
    [ "1", "10000" ].each do |size|
      expect { described_class.new(connection: connection, batch_size: size) }.not_to raise_error
    end
    [ "0", "-1", "10001", "abc", "1.5", nil ].each do |size|
      expect { described_class.new(connection: connection, batch_size: size) }.to raise_error(ArgumentError, /BATCH_SIZE/)
    end
  end

  it "retries the same batch after a deadlock or lock timeout and returns counts without a block" do
    allow_legacy_null_company!
    ids = CheckEvent.insert_all!([ event_attributes, event_attributes ], returning: %w[id]).rows.flatten
    errors = [ ActiveRecord::Deadlocked.new, ActiveRecord::LockWaitTimeout.new ]
    failed_batches = []
    allow(connection).to receive(:exec_query).and_wrap_original do |original, sql, *args|
      if sql.include?("UPDATE check_events AS child") && errors.any?
        failed_batches << sql
        raise errors.shift
      end
      original.call(sql, *args)
    end
    backfill = described_class.new(connection: connection, batch_size: 1)
    allow(backfill).to receive(:sleep)

    expect(backfill.backfill.fetch(:check_events)).to eq(2)
    expect(failed_batches.length).to eq(2)
    expect(failed_batches.uniq.length).to eq(1)
    expect(CheckEvent.where(id: ids).pluck(:company_id)).to eq([ payroll_item.company_id ] * 2)
  end

  it "raises after two retries and leaves the failed batch for a later run" do
    allow_legacy_null_company!
    id = CheckEvent.insert_all!([ event_attributes ], returning: %w[id]).rows.sole.sole
    attempts = 0
    allow(connection).to receive(:exec_query).and_wrap_original do |original, sql, *args|
      if sql.include?("UPDATE check_events AS child")
        attempts += 1
        raise PG::LockNotAvailable
      end
      original.call(sql, *args)
    end
    backfill = described_class.new(connection: connection, batch_size: 1)
    allow(backfill).to receive(:sleep)

    expect { backfill.backfill }.to raise_error(PG::LockNotAvailable)
    expect(attempts).to eq(3)
    expect(CheckEvent.find(id).company_id).to be_nil
  end

  it "skips an orphaned row, fills the next batch and reports the remaining null" do
    allow_legacy_null_company!
    connection.remove_foreign_key :check_events, column: :payroll_item_id
    rows = [ event_attributes.merge(payroll_item_id: -1), event_attributes ]
    orphan_id, valid_id = CheckEvent.insert_all!(rows, returning: %w[id]).rows.flatten
    backfill = described_class.new(connection: connection, batch_size: 1)
    # Fixtures already opened a read/write transaction. The task spec also
    # exercises verification in a fresh read-only transaction.
    allow(connection).to receive(:execute).and_call_original
    allow(connection).to receive(:execute).with("SET TRANSACTION READ ONLY")

    expect(backfill.backfill.fetch(:check_events)).to eq(1)
    expect(CheckEvent.find(orphan_id).company_id).to be_nil
    expect(CheckEvent.find(valid_id).company_id).to eq(payroll_item.company_id)
    results = {}
    backfill.verify { |table, nulls, fk_state| results[table] = [ nulls, fk_state ] }
    expect(results.keys).to eq(M3_7ChildCompanies::CHILDREN.keys)
    expect(results.fetch(:check_events)).to eq([ 1, "valid" ])
  end

  it "can run the composite FK rollback twice and preserves the original parent FKs" do
    migration = ConstrainPayrollChildCompanies.new
    migration.suppress_messages { 2.times { migration.migrate(:down) } }

    M3_7ChildCompanies::CHILDREN.each do |table, (key, parent)|
      expect(connection.foreign_key_exists?(table, name: M3_7ChildCompanies.foreign_key_name(table))).to be(false)
      expect(connection.foreign_key_exists?(table, parent, column: key)).to be(true)
    end
  end

  M3_7ChildCompanies::CHILDREN.each do |table, (parent_key, parent_table)|
    it "sets #{table}.company_id in the model's save callback with a validated parent FK and requires it" do
      model = table == :payroll_imports ? PayrollImportRecord : table.to_s.classify.constantize
      association = parent_key.to_s.delete_suffix("_id")
      company = create(:company)
      parent = model.reflect_on_association(association).klass.new(company: company)
      child = model.new(association => parent)

      child.run_callbacks(:save) { expect(child.company_id).to eq(company.id) }
      foreign_key = connection.foreign_keys(table).find { |fk| fk.name == M3_7ChildCompanies.foreign_key_name(table) }
      expect(foreign_key).to have_attributes(to_table: parent_table.to_s, column: [ parent_key.to_s, "company_id" ],
        primary_key: %w[id company_id], validate?: true)
      expect(model.columns_hash.fetch("company_id").null).to be(false)
    end
  end
end
