# frozen_string_literal: true

require "rails_helper"

RSpec.describe PayrollChildCompanyBackfill do
  let(:connection) { ApplicationRecord.connection }
  let(:payroll_item) { create(:payroll_item) }
  let(:event_attributes) do
    { payroll_item_id: payroll_item.id, event_type: "printed", check_number: "100", effective_on: Date.current }
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
    connection.execute("ALTER TABLE check_events DISABLE TRIGGER fill_check_events_company_id")
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

  M3_7ChildCompanies::CHILDREN.each do |table, (parent_key, parent_table)|
    it "sets #{table}.company_id in the model's create callback with a validated parent FK" do
      model = table == :payroll_imports ? PayrollImportRecord : table.to_s.classify.constantize
      association = parent_key.to_s.delete_suffix("_id")
      parent = model.reflect_on_association(association).klass.new(company_id: 123)
      child = model.new(association => parent)

      child.run_callbacks(:create) { expect(child.company_id).to eq(123) }
      foreign_key = connection.foreign_keys(table).find { |fk| fk.name == M3_7ChildCompanies.foreign_key_name(table) }
      expect(foreign_key).to have_attributes(to_table: parent_table.to_s, column: [ parent_key.to_s, "company_id" ],
        primary_key: %w[id company_id], validate?: true)
      expect(model.columns_hash.fetch("company_id").null).to be(true)
    end
  end
end
