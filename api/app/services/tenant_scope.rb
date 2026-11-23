# frozen_string_literal: true

class TenantScope
  class MissingContextError < StandardError; end
  class ConflictingContextError < StandardError; end

  Context = Data.define(:company_id, :mode)
  STATE_KEY = :payroll_tenant_scope

  def self.with_company(company_id, &)
    return yield unless RlsContextGuard.enabled?

    id = company_id.to_s
    unless id.match?(/\A[1-9]\d{0,18}\z/) && id.to_i <= 2**63 - 1
      raise ArgumentError, "TenantScope requires a positive company ID"
    end

    enter(id, "company", &)
  end

  def self.as_system(reason:, &)
    raise ArgumentError, "TenantScope requires a system reason" if reason.blank?
    return yield unless RlsContextGuard.enabled?

    enter(nil, "system", &)
  end

  def self.current
    ActiveSupport::IsolatedExecutionState[STATE_KEY]
  end

  def self.enter(company_id, mode)
    if (context = current)
      return yield if context.company_id == company_id && context.mode == mode

      raise ConflictingContextError, "Cannot change tenant scope inside an active scope"
    end

    ActiveRecord::Base.connection_pool.with_connection(prevent_permanent_checkout: true) do |connection|
      bypass = RlsDatabase.bypass_enabled?(connection)
      ActiveSupport::IsolatedExecutionState[STATE_KEY] = Context.new(company_id, mode)
      connection.with_tenant_settings(bypass ? nil : company_id, bypass ? "system" : mode) { yield }
    ensure
      ActiveSupport::IsolatedExecutionState.delete(STATE_KEY)
    end
  end
  private_class_method :enter
end
