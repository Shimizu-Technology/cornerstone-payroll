# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeStatusEvent do
  let(:employee) { create(:employee) }
  let(:event) do
    described_class.create!(employee: employee, company: employee.company,
      event_type: "deactivated", previous_status: "active", resulting_status: "inactive",
      effective_date: Date.current, source: "operator")
  end

  it "records an inactive transition and rejects a mismatched resulting status" do
    expect(event).to be_persisted
    invalid = event.dup
    invalid.resulting_status = "active"
    expect(invalid).not_to be_valid
    expect(invalid.errors[:resulting_status]).to include("does not match the event type")
  end

  it "prevents changing or deleting the recorded event" do
    expect(event.update(internal_notes: "Changed")).to be(false)
    expect(event.destroy).to be(false)
    expect(event.reload.event_type).to eq("deactivated")
  end
end
