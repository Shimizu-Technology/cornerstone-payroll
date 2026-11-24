# frozen_string_literal: true

module EmployeeContactHygiene
  class ClearSharedEmailService
    class Error < StandardError; end
    class Forbidden < Error; end

    Result = Struct.new(
      :company_id,
      :company_name,
      :email,
      :cleared_count,
      :active_cleared_count,
      :inactive_cleared_count,
      :employee_ids,
      keyword_init: true
    )

    def initialize(company:, email:, actor:, ip_address: nil, user_agent: nil, request_id: nil)
      @company = company
      @raw_email = email
      @actor = actor
      @ip_address = ip_address
      @user_agent = user_agent
      @request_id = request_id
    end

    def call!
      authorize!
      normalized_email = EmployeeContactValidator.normalize_email(@raw_email)
      raise Error, "Email address is required" if normalized_email.blank?

      # Uses the exact same placeholder classification as SharedEmailReport and
      # EmployeeContactValidator. Unmarked duplicates (e.g., family emails) can
      # never be bulk-cleared until staff explicitly mark them as a placeholder.
      unless EmployeeContactValidator.placeholder_email?(normalized_email, organization_id: @company.organization_id)
        raise Error, "Only marked or structural placeholder email addresses can be cleared in bulk. Mark this address as a placeholder first."
      end

      result = nil
      now = Time.current

      Employee.transaction do
        @company.lock!
        authorize!

        matching = @company.employees
          .where("LOWER(TRIM(email)) = ?", normalized_email)
          .order(:id)
          .lock
          .to_a

        # Retries after a successful clear return a 200 no-op with zero audit rows.
        if matching.empty?
          result = Result.new(
            company_id: @company.id,
            company_name: @company.name,
            email: normalized_email,
            cleared_count: 0,
            active_cleared_count: 0,
            inactive_cleared_count: 0,
            employee_ids: []
          )
          next
        end

        cleared_ids = matching.map(&:id)
        active_count = matching.count(&:active?)
        inactive_count = cleared_ids.size - active_count

        @company.employees.where(id: cleared_ids).update_all(
          email: nil,
          email_verified_at: nil,
          contact_source: "staff",
          updated_at: now
        )

        AuditLog.record!(
          user: @actor,
          organization_id: @company.organization_id,
          company_id: @company.id,
          action: "employee_contact_hygiene#clear_shared_emails",
          record_type: "companies",
          record_id: @company.id,
          subject_name: @company.name,
          metadata: {
            email: normalized_email,
            cleared_count: cleared_ids.size,
            active_cleared_count: active_count,
            inactive_cleared_count: inactive_count,
            employee_ids: cleared_ids
          },
          ip_address: @ip_address,
          user_agent: @user_agent,
          request_id: @request_id
        )

        record_employee_audit_entries!(matching, now: now)

        result = Result.new(
          company_id: @company.id,
          company_name: @company.name,
          email: normalized_email,
          cleared_count: cleared_ids.size,
          active_cleared_count: active_count,
          inactive_cleared_count: inactive_count,
          employee_ids: cleared_ids
        )
      end

      result
    end

    private

    def authorize!
      allowed = @actor.present? &&
        @company.present? &&
        @actor.can_access_company?(@company.id) &&
        StaffRolePolicy.allowed?(@actor, :manage_client_configuration, company: @company)
      raise Forbidden, StaffRolePolicy.error_message(:manage_client_configuration) unless allowed
    end

    def record_employee_audit_entries!(employees, now:)
      audit_actor = AuditActor.for_user(@actor)
      rows = employees.map do |emp|
        {
          user_id: @actor.id,
          organization_id: @company.organization_id,
          company_id: @company.id,
          action: "employees#clear_shared_email",
          record_type: "employees",
          record_id: emp.id,
          subject_name: emp.display_name,
          metadata: {
            bulk_clear: true,
            changed_fields: %w[contact_source email email_verified_at],
            before_values: {
              "email" => emp.email,
              "email_verified_at" => emp.email_verified_at&.iso8601,
              "contact_source" => emp.contact_source
            },
            after_values: {
              "email" => nil,
              "email_verified_at" => nil,
              "contact_source" => "staff"
            }
          },
          ip_address: @ip_address,
          user_agent: @user_agent,
          request_id: @request_id,
          event_category: "activity",
          actor_type: audit_actor&.type,
          actor_id: audit_actor&.id,
          actor_name: audit_actor&.name,
          actor_email: audit_actor&.email,
          actor_role: audit_actor&.role,
          created_at: now
        }
      end

      AuditLog.insert_all!(rows) if rows.any?
    end
  end
end
