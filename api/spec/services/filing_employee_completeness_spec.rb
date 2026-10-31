# frozen_string_literal: true

require "rails_helper"

RSpec.describe FilingEmployeeCompleteness do
  it "lists each affected profile once without identity values and clears when details are supplied" do
    employee = create(:employee)
    employee.update_columns(ssn_encrypted: "12345678", city: nil)
    result = described_class.for([ employee.reload ])
    expect(result).to include(missing_ssn_count: 1, missing_address_count: 1)
    expect(result[:employees]).to eq([ { employee_id: employee.id, name: employee.full_name, missing_fields: %w[ssn address], edit_path: "/companies/#{employee.company_id}/employees/#{employee.id}/edit" } ])
    expect(result.to_json).not_to include("12345678", employee.address_line1, "ssn_encrypted")
    employee.update_columns(ssn_encrypted: "123-45-6789", city: "Tamuning")
    expect(described_class.for([ employee.reload ])).to include(message: nil, employees: [], missing_ssn_count: 0, missing_address_count: 0)
  end
end
