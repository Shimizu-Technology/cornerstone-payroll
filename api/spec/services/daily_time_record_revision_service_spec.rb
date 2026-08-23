# frozen_string_literal: true

require "rails_helper"

RSpec.describe DailyTimeRecordRevisionService do
  let(:employee) { create(:employee) }
  let(:record) do
    create(
      :daily_time_record,
      employee: employee,
      company: employee.company,
      scheduled_hours: 8,
      actual_worked_hours: nil,
      source: "schedule"
    )
  end

  it "creates an immutable replacement and retains the prior revision" do
    replacement = described_class.call!(
      record: record,
      attributes: { actual_worked_hours: 7.5, override_reason: "Corrected from signed timecard" }
    )

    expect(record.reload.superseded_at).to be_present
    expect(replacement).to have_attributes(
      supersedes_id: record.id,
      revision: 2,
      source: "manual",
      actual_worked_hours: 7.5.to_d,
      override_reason: "Corrected from signed timecard"
    )
    expect(employee.daily_time_records.count).to eq(2)
    expect(employee.daily_time_records.current).to contain_exactly(replacement)
  end

  it "rejects a second correction of a superseded revision" do
    described_class.call!(
      record: record,
      attributes: { actual_worked_hours: 7.5, override_reason: "Corrected from signed timecard" }
    )

    expect {
      described_class.call!(
        record: record,
        attributes: { actual_worked_hours: 7, override_reason: "Second correction attempt" }
      )
    }.to raise_error(described_class::Error, /current time record/)
  end

  it "requires a meaningful correction reason" do
    expect {
      described_class.call!(
        record: record,
        attributes: { actual_worked_hours: 7.5, override_reason: "no" }
      )
    }.to raise_error(described_class::Error, /correction reason/i)

    expect(record.reload.superseded_at).to be_nil
    expect(employee.daily_time_records.count).to eq(1)
  end
end
