# frozen_string_literal: true

# Staff can resolve outstanding lifecycle work after a company rolls back.
module StaffEmployeeLifecycle
  def self.unlocked?
    !CompanyFeatures::LOCKED_OFF.include?("client_portal.employee_lifecycle_mode")
  end

  def self.available?(company, client_managed_only: false)
    return false unless unlocked? && company

    today = PayrollBusinessClock.today
    return true if CompanyFeatures.for(company, on: today).client_managed_employee_lifecycle?
    return false if client_managed_only

    with_residual_work(Company.where(id: company.id), today).exists?
  end

  def self.companies(scope)
    return scope.none unless unlocked?

    today = PayrollBusinessClock.today
    # Resolve the effective row before checking whether that row is activated.
    profiles = ClientOperatingProfile.active_on(today).where(company_id: scope.select(:id))
      .select("DISTINCT ON (company_id) company_id, client_portal_enabled, lifecycle_mode_activated_at, options")
      .reorder(:company_id, effective_on: :desc, version: :desc)
    client_managed = ClientOperatingProfile.from(profiles, :client_operating_profiles)
      .where(client_portal_enabled: true).where.not(lifecycle_mode_activated_at: nil)
      .where("options -> 'client_portal' ->> 'employee_lifecycle_mode' = ?", "client_managed")
      .select(:company_id)

    scope.where(id: client_managed).or(with_residual_work(scope, today))
  end

  private_class_method def self.with_residual_work(scope, today)
    open_items = EmployeeVerificationItem.open_items.where("employee_verification_items.company_id = companies.id")
    gated_employees = Employee.where(readiness_gate_enforced: true).where("employees.company_id = companies.id")
    active_overrides = EmployeeReadinessOverride.active.left_joins(:pay_period)
      .where("employee_readiness_overrides.company_id = companies.id")
    dated_overrides = active_overrides.where(pay_period_id: nil, expires_on: today..)
    pinned_overrides = active_overrides.where(pay_periods: {
      status: EmployeeReadinessOverrides::Manage::OPEN_PERIOD_STATUSES, committed_at: nil
    }).where("pay_periods.correction_status IS DISTINCT FROM 'voided'")

    scope.where(open_items.arel.exists)
      .or(scope.where(gated_employees.arel.exists))
      .or(scope.where(dated_overrides.or(pinned_overrides).arel.exists))
  end
end
