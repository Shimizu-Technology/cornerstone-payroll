# frozen_string_literal: true

module EmployeeLifecyclePr4Helpers
  def unlock_lifecycle_mode!
    key = "client_portal.employee_lifecycle_mode"
    stub_const("CompanyFeatures::LOCKED_OFF", CompanyFeatures::LOCKED_OFF - [ key ])
  end

  def create_client_managed_profile!(company, **attributes)
    ClientOperatingProfile.create!(
      ClientOperatingProfiles::LegacyProfileBuilder.attributes_for(company, effective_on: Date.new(2026, 1, 1)).merge(
        client_portal_enabled: true,
        options: { "client_portal" => { "employee_lifecycle_mode" => "client_managed" } },
        lifecycle_mode_activated_at: Time.current
      ).merge(attributes)
    )
  end

  def create_lifecycle_worker!(company, **attributes)
    create(:employee, company: company, department: create(:department, company: company),
      first_name: "Quinn", last_name: "Example", ssn_encrypted: "900-11-2233",
      date_of_birth: Date.new(1995, 5, 1), hire_date: Date.new(2026, 1, 1),
      address_line1: "100 Example Street", city: "Fixture City",
      payment_delivery_method: "paper_check", readiness_gate_enforced: true, **attributes)
  end
end
