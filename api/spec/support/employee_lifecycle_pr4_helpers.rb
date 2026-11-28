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

  def roll_back_lifecycle_mode!(company, actor:)
    today = PayrollBusinessClock.today
    create(:pay_period, company: company, start_date: today, end_date: today + 13.days, pay_date: today + 19.days)
    previous = company.client_operating_profiles.history_order.first
    ClientOperatingProfiles::UpdateService.new(company: company, actor: actor,
      effective_on: today.iso8601, lock_version: previous.lock_version,
      reason: "Return the synthetic client to approval first.",
      changes: { "client_portal.employee_lifecycle_mode" => "approval_first" }).call
  end

  def create_lifecycle_worker!(company, **attributes)
    create(:employee, company: company, department: create(:department, company: company),
      first_name: "Quinn", last_name: "Example", ssn_encrypted: "900-11-2233",
      date_of_birth: Date.new(1995, 5, 1), hire_date: Date.new(2026, 1, 1),
      address_line1: "100 Example Street", city: "Fixture City",
      payment_delivery_method: "paper_check", readiness_gate_enforced: true, **attributes)
  end
end
