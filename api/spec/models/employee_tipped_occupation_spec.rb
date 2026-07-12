# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeTippedOccupation, type: :model do
  it "requires a three-digit occupation code" do
    occupation = build(:employee_tipped_occupation, occupation_code: "12")

    expect(occupation).not_to be_valid
  end

  it "rejects overlapping effective periods for the same code" do
    employee = create(:employee)
    create(:employee_tipped_occupation,
      employee: employee,
      occupation_code: "101",
      effective_from: Date.new(2026, 1, 1),
      effective_to: Date.new(2026, 6, 30))

    overlapping = build(:employee_tipped_occupation,
      employee: employee,
      occupation_code: "101",
      effective_from: Date.new(2026, 6, 1))

    expect(overlapping).not_to be_valid
    expect(overlapping.errors[:base]).to include("occupation code has an overlapping effective period")
  end
end
