# frozen_string_literal: true

# Safe to expose in filing review responses: never serialize identity values.
class FilingEmployeeCompleteness
  def self.for(employees)
    warnings = employees.filter_map do |employee|
      missing = []
      missing << "ssn" unless employee.valid_filing_ssn?
      missing << "address" if [ employee.address_line1, employee.city, employee.state, employee.zip ].any?(&:blank?)
      next if missing.empty?

      {
        employee_id: employee.id,
        name: employee.full_name,
        missing_fields: missing,
        edit_path: "/companies/#{employee.company_id}/employees/#{employee.id}/edit"
      }
    end
    ssn_count = warnings.count { |warning| warning[:missing_fields].include?("ssn") }
    address_count = warnings.count { |warning| warning[:missing_fields].include?("address") }
    {
      missing_ssn_count: ssn_count,
      missing_address_count: address_count,
      message: warnings.empty? ? nil : "#{ssn_count} #{ssn_count == 1 ? "employee is" : "employees are"} missing a 9-digit SSN and #{address_count} #{address_count == 1 ? "is" : "are"} missing a complete address. Missing details will print blank on the SW-2/W-2. Add them on each employee's profile before filing. Drafts can still be generated.",
      employees: warnings
    }
  end
end
