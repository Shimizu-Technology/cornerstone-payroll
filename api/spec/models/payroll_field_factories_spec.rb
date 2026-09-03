# frozen_string_literal: true

require "rails_helper"

RSpec.describe "payroll field factories" do
  it "creates a payroll item entry whose definition belongs to the payroll item's company" do
    entry = create(:payroll_item_field_entry)

    expect(entry.payroll_field_definition.company).to eq(entry.payroll_item.company)
  end
end
