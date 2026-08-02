# frozen_string_literal: true

require "rails_helper"

RSpec.describe EmployeeBulkImport::ImportService, type: :service do
  subject(:service) { described_class.new(create(:company)) }

  let(:complete_row) do
    {
      "first_name" => "Alex",
      "last_name" => "Worker",
      "employment_type" => "hourly",
      "pay_rate" => "15.00",
      "pay_frequency" => "biweekly",
      "hire_date" => "2026-01-01",
      "address_line1" => "123 Marine Corps Dr",
      "city" => "Hagatna",
      "state" => "GU",
      "zip" => "96910",
      "ssn" => "123-45-6789"
    }
  end

  it "accepts complete W-2 filing data" do
    expect(service.send(:validate_row_data, complete_row)).to be_empty
  end

  it "reports missing common filing data and SSN during preview" do
    errors = service.send(:validate_row_data, complete_row.except("hire_date", "address_line1", "ssn"))

    expect(errors).to include(
      "hire_date is required",
      "address_line1 is required",
      "ssn is required for W-2 employees and individual contractors"
    )
  end

  it "requires legal business name and EIN instead of SSN for business contractors" do
    row = complete_row.merge(
      "employment_type" => "contractor",
      "contractor_type" => "business",
      "contractor_pay_type" => "flat_fee",
      "ssn" => "",
      "business_name" => "AIRE Services LLC",
      "contractor_ein" => "12-3456789"
    )

    expect(service.send(:validate_row_data, row)).to be_empty
  end
end
