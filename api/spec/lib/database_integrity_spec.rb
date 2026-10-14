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
end
