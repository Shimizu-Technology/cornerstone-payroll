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
      "w4_effective_on" => "2026-01-01",
      "address_line1" => "123 Marine Corps Dr",
      "city" => "Hagatna",
      "state" => "GU",
      "zip" => "96910",
      "ssn" => "123-45-6789"
    }
  end

  it "shows only the active intake requirements in missing-header errors" do
    service.company.update!(employee_intake_expires_at: 1.hour.from_now)
    service.send(:validate_headers, [ "first_name" ])
    expect(service.errors.first).to eq("Missing required columns: last_name, employment_type, pay_rate, pay_frequency. Required: first_name, last_name, employment_type, pay_rate, pay_frequency")
  end

  it "validates each preview row's contact details once" do
    company = create(:company)
    import_service = described_class.new(company)
    headers = complete_row.keys
    expect(EmployeeContactValidator).to receive(:call).once.and_call_original

    row = import_service.send(:parse_row, headers.map { |key| complete_row[key] }, headers, 2, {}, Set.new, Set.new, Set.new, Hash.new(0))

    expect(row[:errors]).to be_empty
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

  it "records the imported W-4 election with its effective date and actor" do
    company = create(:company)
    actor = create(:user, company: company, organization: company.organization, role: "admin")
    import_service = described_class.new(company, actor: actor)
    attributes = import_service.send(:build_attributes, complete_row.merge("w4_effective_on" => "2026-01-15"), {})

    result = import_service.create_employees!([
      { row_number: 2, attributes: attributes, raw: complete_row }
    ])

    expect(result).to include(created: 1, failed: 0)
    expect(company.employees.sole.created_by_id).to eq(actor.id)
    expect(company.employees.sole.employee_w4_elections.sole).to have_attributes(
      effective_on: Date.new(2026, 1, 15),
      source: "employee_creation",
      created_by_id: actor.id
    )
  end

  it "runs shared contact validation, normalizes Guam phones, warns on coworker/structural emails, and rejects marked placeholders" do
    company = create(:company)
    EmployeePlaceholderEmail.create!(organization: company.organization, email: "marked-placeholder@example.com")
    create(:employee, company: company, first_name: "Existing", last_name: "Family", email: "family.bulk@example.com")
    create(:user, company: company, organization: company.organization, role: "admin", name: "Staff Person", email: "staff.bulk@example.com")
    import_service = described_class.new(company)

    expect(import_service.send(:validate_row_data, complete_row.merge("email" => "marked-placeholder@example.com"))).to include(/placeholder/i)
    expect(import_service.send(:validate_row_data, complete_row.merge("email" => "noemail@example.com"))).to be_empty
    expect(import_service.send(:validate_row_data, complete_row.merge("email" => "staff.bulk@example.com"))).to include(/another person's payroll login/i)
    expect(import_service.send(:validate_row_data, complete_row.merge("phone" => "not-a-phone"))).to include(/valid phone/i)

    valid_row = complete_row.merge("email" => "Family.Bulk@Example.com", "phone" => "555-0190")
    attrs = import_service.send(:build_attributes, valid_row, {})
    result = import_service.create_employees!([ { row_number: 2, attributes: attrs, raw: valid_row } ])

    expect(result).to include(created: 1, failed: 0)
    expect(result[:warnings].first[:warnings].first).to include(code: "shared_company_email")
    created = company.employees.find_by!(first_name: "Alex", last_name: "Worker")
    expect(created).to have_attributes(
      email: "family.bulk@example.com",
      phone: "+16715550190",
      contact_source: "import",
      email_verified_at: nil
    )
  end
end
