# frozen_string_literal: true

require "rails_helper"

RSpec.describe DatabaseIntegrity do
  it "has every migration-defined trigger in its current versioned snapshot" do
    expected = Rails.root.glob("db/migrate/*.rb").flat_map { |path| path.read.scan(/CREATE TRIGGER\s+(\w+)/).flatten }.uniq
    actual = File.read(described_class::PATH).scan(/CREATE TRIGGER\s+(\w+)/).flatten.uniq
    expect(actual).to match_array(expected)
    pattern = /CREATE (?:OR REPLACE )?FUNCTION\s+(\w+)\([^)]*\)(.*?)(\$[a-zA-Z0-9_]*\$)(.*?)\3(.*?);/m
    normalize = ->(matches) do
      matches.to_h do |name, header, _delimiter, body, tail|
        [ name, [ body.strip_heredoc.strip, "#{header} #{tail}"[/LANGUAGE\s+(\w+)/, 1] ] ]
      end
    end
    migrations = Rails.root.glob("db/migrate/*.rb").sort.flat_map { |path| path.read.scan(pattern) }
    expect(normalize.call(File.read(described_class::PATH).scan(pattern))).to eq(normalize.call(migrations))
    expect(described_class.verify!).to eq(true)
  end

  it "restores a missing filing guard idempotently and rejects mutation without changing saved evidence" do
    connection = ApplicationRecord.connection
    connection.execute("DROP TRIGGER payroll_filing_events_append_only ON payroll_filing_events")
    expect { described_class.verify! }.to raise_error(/payroll_filing_events_append_only/)
    expect(described_class.install!).to eq(true)
    expect(described_class.install!).to eq(true)
    # The existing filing lifecycle examples exercise valid insertion and
    # updates with real evidence. Here the UPDATE command must remain guarded
    # even when Rails validations are bypassed.
    definition = connection.select_value("SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname = 'payroll_filing_events_append_only' AND tgrelid = 'payroll_filing_events'::regclass")
    expect(definition).to include("BEFORE DELETE OR UPDATE", "prevent_payroll_filing_event_mutation")
  end

  it "rejects a replaced function body even when its trigger name is still present" do
    ApplicationRecord.connection.execute(<<~SQL)
      CREATE OR REPLACE FUNCTION prevent_payroll_filing_event_mutation()
      RETURNS trigger AS $$ BEGIN RETURN NEW; END; $$ LANGUAGE plpgsql;
    SQL
    expect { described_class.verify! }.to raise_error(/integrity functions differ:.*prevent_payroll_filing_event_mutation/)
    described_class.install!
    expect(described_class.verify!).to eq(true)
  end

  it "rejects a trigger with its original name and function but missing the DELETE guard" do
    ApplicationRecord.connection.execute(<<~SQL)
      DROP TRIGGER payroll_filing_events_append_only ON payroll_filing_events;
      CREATE TRIGGER payroll_filing_events_append_only BEFORE UPDATE ON payroll_filing_events
      FOR EACH ROW EXECUTE FUNCTION prevent_payroll_filing_event_mutation();
    SQL
    expect { described_class.verify! }.to raise_error(/trigger definitions differ:.*payroll_filing_events_append_only/)
    described_class.install!
    expect(described_class.verify!).to eq(true)
  end

  it "rejects replica-only firing and restores protection for ordinary origin writes" do
    connection = ApplicationRecord.connection
    connection.execute("ALTER TABLE payroll_filing_events ENABLE REPLICA TRIGGER payroll_filing_events_append_only")
    expect { described_class.verify! }.to raise_error(/guards missing:.*payroll_filing_events_append_only/)
    described_class.install!
    mode = connection.select_value("SELECT tgenabled FROM pg_trigger WHERE tgname = 'payroll_filing_events_append_only' AND tgrelid = 'payroll_filing_events'::regclass")
    expect(mode).to eq("O")
    expect(described_class.verify!).to eq(true)
  end
end

RSpec.describe "Schema database targeting" do
  self.use_transactional_tests = false

  it "loads each actual secondary schema without touching primary payroll guards" do
    primary = ActiveRecord::Base.connection_pool
    original_guards = primary.with_connection { |connection| connection.select_values("SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE NOT tgisinternal ORDER BY tgname") }
    %w[cache queue cable].each do |name|
      primary = ActiveRecord::Base.connection_pool
      namespace = "integrity_secondary_#{name}_#{SecureRandom.hex(4)}"
      primary.with_connection { |connection| connection.execute("CREATE SCHEMA #{namespace}") }
      config = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, name,
        primary.db_config.configuration_hash.merge(schema_search_path: namespace))
      expect(config.primary?).to eq(false)
      expect(DatabaseIntegrity).not_to receive(:install!)
      ActiveRecord::Tasks::DatabaseTasks.send(:with_temporary_pool, config) do |pool|
        load Rails.root.join("db/#{name}_schema.rb")
        pool.with_connection do |connection|
          expect(connection.select_value("SELECT current_schema()")).to eq(namespace)
          expect(connection.tables).not_to include("payroll_items")
          expect(connection.tables).to include("solid_#{name == 'queue' ? 'queue_jobs' : name == 'cache' ? 'cache_entries' : 'cable_messages'}")
        end
      end
    ensure
      ActiveRecord::Base.connection_pool.with_connection { |connection| connection.execute("DROP SCHEMA IF EXISTS #{namespace} CASCADE") }
    end
    expect(DatabaseIntegrity.verify!).to eq(true)
    expect(ActiveRecord::Base.connection_pool.with_connection { |connection| connection.select_values("SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE NOT tgisinternal ORDER BY tgname") }).to eq(original_guards)
  end

  it "installs and verifies the actual primary target connection in an isolated schema" do
    primary = ActiveRecord::Base.connection_pool
    namespace = "integrity_primary_#{SecureRandom.hex(4)}"
    primary.with_connection { |connection| connection.execute("CREATE SCHEMA #{namespace}") }
    config = ActiveRecord::DatabaseConfigurations::HashConfig.new(Rails.env, "primary",
      primary.db_config.configuration_hash.merge(schema_search_path: namespace))
    expect(config.primary?).to eq(true)
    installed_connections = []
    allow(DatabaseIntegrity).to receive(:install!).and_wrap_original do |method, connection|
      installed_connections << connection
      expect(connection.select_value("SELECT current_schema()")).to eq(namespace)
      method.call(connection)
    end
    ActiveRecord::Tasks::DatabaseTasks.send(:with_temporary_pool, config) do |pool|
      load Rails.root.join("db/schema.rb")
      pool.with_connection do |connection|
        expect(installed_connections).to eq([ connection ])
        expect(DatabaseIntegrity.verify!(connection)).to eq(true)
      end
    end
  ensure
    ActiveRecord::Base.connection_pool.with_connection { |connection| connection.execute("DROP SCHEMA IF EXISTS #{namespace} CASCADE") } if namespace
  end
end
