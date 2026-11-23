# frozen_string_literal: true

class ApplicationJob < ActiveJob::Base
  class_attribute :rls_mode, instance_writer: false

  def perform_now
    # Active Job handles retries and discards after the perform callbacks unwind.
    with_job_rls_scope do
      Current.with_isolated_actor(AuditActor.system_job(self)) { super }
    end
  end

  private

  def with_job_rls_scope(&perform)
    case rls_mode
    when :system
      TenantScope.as_system(reason: self.class.name, &perform)
    when :record
      # A standalone worker receives a record ID, not a tenant ID. When run
      # inline by a tenant operation, the existing scope constrains the lookup.
      return yield if TenantScope.current

      TenantScope.as_system(reason: "#{self.class.name} resolves its work from a queued record ID", &perform)
    when :company
      return yield if TenantScope.current&.mode == "system"

      TenantScope.with_company(arguments.first, &perform)
    else
      yield
    end
  end
end
