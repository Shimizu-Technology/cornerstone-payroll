# frozen_string_literal: true

# This does not make the worker payable. Filing details are unavailable in AIRE;
# an administrator must complete the inactive profile and its setup review.
class SeedVerifiedAireMaintenanceOnboarding < ActiveRecord::Migration[8.0]
  COMPANY_ID = 2
  SOURCE_ID = 1
  SOURCE_USER_ID = "39"
  SOURCE_UUID = "b726ad82-8589-41d1-80ce-ce74de6f9621"
  RATE = BigDecimal("16.00")

  def up
    company = Company.find_by(id: COMPANY_ID)
    if company.nil?
      raise "AIRE payroll company is missing" if Rails.env.production?

      return
    end
    raise "AIRE payroll company changed" unless company.name == "AIRE Services"

    source = company.time_tracking_sources.find_by(id: SOURCE_ID)
    raise "AIRE source changed" unless source&.source_type == "aire_services"

    by_id = source.time_tracking_employee_mappings.find_by(source_user_id: SOURCE_USER_ID)
    by_uuid = source.time_tracking_employee_mappings.find_by(source_user_uuid: SOURCE_UUID)
    if by_id || by_uuid
      raise "Francisco's permanent AIRE identity conflicts with a saved mapping" unless by_id&.id == by_uuid&.id

      verify_existing!(by_id.employee)
      return
    end

    duplicate = company.employees.where("LOWER(TRIM(first_name)) = ? AND LOWER(TRIM(last_name)) = ?", "francisco", "san nicolas")
    raise "A Francisco payroll profile already exists; review before linking" if duplicate.exists?

    employee = company.employees.create!(
      first_name: "Francisco",
      last_name: "San Nicolas",
      employment_type: "hourly",
      pay_frequency: "semimonthly",
      pay_rate: RATE,
      status: "inactive",
      configuration_source: "aire_onboarding",
      configuration_review_status: "needs_review",
      configuration_review_items: [
        {
          "code" => "aire_filing_details_missing",
          "message" => "Complete Francisco's hire date, address, SSN, and signed W-4 before payroll activation.",
          "fields" => %w[hire_date address_line1 city state zip ssn_encrypted w4_signed_on]
        },
        {
          "code" => "certify_employee_profile",
          "message" => "Verify W-2 classification, $16 maintenance rate, withholding, and payment method with the employer.",
          "fields" => %w[employment_type pay_rate filing_status payment_delivery_method]
        }
      ]
    )
    employee.employee_wage_rates.create!(label: "Maintenance", rate: RATE, is_primary: true, active: true)
    source.time_tracking_employee_mappings.create!(
      company: company, employee: employee,
      source_user_id: SOURCE_USER_ID, source_user_uuid: SOURCE_UUID
    )
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "A linked payroll identity and rate cannot be safely deleted"
  end

  private

  def verify_existing!(employee)
    return if employee.first_name == "Francisco" && employee.last_name == "San Nicolas" &&
              employee.employment_type == "hourly" && employee.pay_rate == RATE &&
              employee.employee_wage_rates.where(label: "Maintenance", rate: RATE, active: true).exists?

    raise "Francisco's linked payroll setup differs from the verified $16 W-2 maintenance profile"
  end
end
