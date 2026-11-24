# frozen_string_literal: true

# The only employee fields the Contact details page needs: names, contact
# details, their verification and source, and the row revision. Pay, tax,
# identity and banking fields never reach that page.
module EmployeeContactProjection
  FIELDS = %w[
    id company_id first_name middle_name last_name status
    email phone address_line1 address_line2 city state zip
    email_verified_at phone_confirmed_by_employee_at contact_source updated_at
  ].freeze

  def self.call(employee, context: nil)
    employee.slice(*FIELDS).as_json.merge(
      "contact_revision" => employee.contact_revision,
      "contact_details_status" => EmployeeContactValidator.contact_details_status(employee, context: context)
    )
  end

  def self.requested?(params)
    params[:view].to_s == "contact" || params[:response_view].to_s == "contact"
  end
end
