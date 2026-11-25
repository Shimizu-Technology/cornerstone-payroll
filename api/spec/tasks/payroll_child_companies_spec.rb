# frozen_string_literal: true

require "rails_helper"
require "rake"

RSpec.describe "Payroll child company tasks" do
  around do |example|
    Rake.with_application do
      Rake::Task.define_task(:environment)
      load Rails.root.join("lib/tasks/payroll_child_companies.rake")
      example.run
    end
  end

  it "backfills a legacy row and prints its count using BATCH_SIZE" do
    item = create(:payroll_item)
    ApplicationRecord.connection.execute("ALTER TABLE check_events DISABLE TRIGGER fill_check_events_company_id")
    ApplicationRecord.connection.change_column_null :check_events, :company_id, true
    id = CheckEvent.insert_all!([ { payroll_item_id: item.id, event_type: "printed", check_number: "123", effective_on: Date.current } ],
      returning: %w[id]).rows.sole.sole
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("BATCH_SIZE", PayrollChildCompanyBackfill::DEFAULT_BATCH_SIZE).and_return("1")

    expect { Rake::Task["payroll_child_companies:backfill"].invoke }.to output(/check_events: updated=1/).to_stdout
    expect(CheckEvent.find(id).company_id).to eq(item.company_id)
  end

  it "reports invalid and missing constraints and exits nonzero" do
    connection = ApplicationRecord.connection
    connection.remove_foreign_key :check_events, name: M3_7ChildCompanies.foreign_key_name(:check_events)
    connection.remove_foreign_key :payroll_imports, name: M3_7ChildCompanies.foreign_key_name(:payroll_imports)
    connection.add_foreign_key :payroll_imports, :pay_periods, column: %i[pay_period_id company_id], primary_key: %i[id company_id],
      name: M3_7ChildCompanies.foreign_key_name(:payroll_imports), validate: false
    allow(connection).to receive(:execute).and_call_original
    allow(connection).to receive(:execute).with("SET TRANSACTION READ ONLY")

    expect do
      expect do
        Rake::Task["payroll_child_companies:verify"].invoke
      end.to raise_error(SystemExit) { |error| expect(error.status).to eq(1) }
    end.to output(/check_events: nulls=0 parent_fk=missing.*payroll_imports: nulls=0 parent_fk=not valid/m).to_stdout
  end

  context "on a fresh connection" do
    self.use_transactional_tests = false

    it "reports every table via a read-only transaction" do
      connection = ApplicationRecord.connection
      backfill = PayrollChildCompanyBackfill.new(connection: connection)
      expect(connection).to receive(:execute).with("SET TRANSACTION READ ONLY").and_call_original
      allow(connection).to receive(:execute).and_call_original
      expect(backfill).to receive(:verify).and_wrap_original do |original, &report|
        original.call do |*row|
          expect(connection.select_value("SHOW transaction_read_only")).to eq("on")
          report.call(*row)
        end
      end
      allow(PayrollChildCompanyBackfill).to receive(:new).with(connection: connection).and_return(backfill)

      expect { Rake::Task["payroll_child_companies:verify"].invoke }
        .to output(/(?:^\w+: nulls=0 parent_fk=valid\n){26}\z/).to_stdout
    end
  end
end
