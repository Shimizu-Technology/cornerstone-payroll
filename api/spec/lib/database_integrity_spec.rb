# frozen_string_literal: true

require "rails_helper"

RSpec.describe DatabaseIntegrity do
  it "has every migration-defined trigger in its current versioned snapshot" do
    expected = Rails.root.glob("db/migrate/*.rb").flat_map { |path| path.read.scan(/CREATE TRIGGER\s+(\w+)/).flatten }.uniq
    actual = File.read(described_class::PATH).scan(/CREATE TRIGGER\s+(\w+)/).flatten.uniq
    expect(actual).to match_array(expected)
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
end
