# frozen_string_literal: true

module CompanyRlsScoped
  extend ActiveSupport::Concern

  included do
    around_action :with_action_rls_scope
  end

  private

  def with_action_rls_scope(&action)
    @rls_action_entered = true
    in_action_rls_scope(&action)
  end

  # Rails dispatches rescue_from after the action callbacks have unwound.
  def rescue_with_handler(...)
    return super unless @rls_action_entered

    in_action_rls_scope { super }
  end

  def in_action_rls_scope(&action)
    return yield unless RlsContextGuard.enabled?
    return TenantScope.as_system(reason: rls_system_reason, &action) if rls_system_reason

    company_id = rls_company_id
    company_id ? TenantScope.with_company(company_id, &action) : yield
  end

  def rls_system_reason
    nil
  end

  def rls_company_id
    current_company_id
  end
end
