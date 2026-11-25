# frozen_string_literal: true

# M4-9d: a profile flag alone opens no part of the employee app; the Employee
# app switch's activation must exist too (CompanyFeatures). Specs that set
# up an open employee app directly record the activations here, the way the
# switch would after its readiness checks.
module EmployeeAppActivationHelpers
  def activate_employee_app!(company, parts = EmployeeAppSwitch::KEYS, actor: nil)
    actor ||= User.where(organization_id: company.organization_id).order(:id).first ||
      FactoryBot.create(:user, company: company, organization: company.organization, role: :org_admin)
    run = lambda do
      Array(parts).each do |part|
        EmployeeAppActivation.activate!(company: company, part: part, actor: actor, checks: [])
      end
    end
    TenantScope.current ? run.call : TenantScope.as_system(reason: "Spec: activate employee app parts", &run)
    TenantSubdomainRegistry.invalidate!
  end
end

RSpec.configure do |config|
  config.include EmployeeAppActivationHelpers
  config.before { EmployeeAppSwitch::Enforcement.reset_cache! }
end
