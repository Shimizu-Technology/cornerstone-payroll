# frozen_string_literal: true

module EmployeeAppSwitch
  # Sets or ends the demo early-access window for an organization. Setting a
  # new window ends the open one. Org admins record the owner-approved expiry
  # and the exact demo companies; the row keeps who set it and when.
  module EarlyAccess
    SET_ACTION = "employee_app_early_access#set"
    END_ACTION = "employee_app_early_access#ended"

    module_function

    def set!(organization:, actor:, expires_on:, company_ids:, reason:, today: PayrollBusinessClock.today)
      reason = EmployeeAppSwitch.reason!(reason)
      date = parse_date(expires_on)
      raise Invalid, "Choose an expiry date from today to #{EmployeeAppEarlyAccessWindow::MAX_DAYS} days ahead." unless
        date && date >= today && date <= today + EmployeeAppEarlyAccessWindow::MAX_DAYS
      ids = parse_ids(company_ids)

      window = EmployeeAppEarlyAccessWindow.transaction do
        organization.lock!
        authorize!(actor, organization)
        demos = Company.demo.active.where(organization_id: organization.id, id: ids).order(:id).to_a
        unless demos.size == ids.size
          raise Invalid, "Choose only active demo companies in this organization. Real companies can't use early access."
        end

        previous = EmployeeAppEarlyAccessWindow.current_for(organization.id)
        end_window!(previous, actor, "Replaced by a new early-access window") if previous
        window = EmployeeAppEarlyAccessWindow.create!(organization: organization, company_ids: ids, expires_on: date,
          reason: reason, set_by: actor)
        audit!(actor, organization, SET_ACTION, window,
          { reason: reason, expires_on: date.iso8601, company_ids: ids, replaced_window_id: previous&.id }.compact)
        window
      end
      # A demo the new window no longer names closes now, not at the next sweep.
      DemoExpiry.call(organization_ids: [ organization.id ])
      window
    end

    def end!(organization:, actor:, reason:)
      reason = EmployeeAppSwitch.reason!(reason)
      window = EmployeeAppEarlyAccessWindow.transaction do
        organization.lock!
        authorize!(actor, organization)
        window = EmployeeAppEarlyAccessWindow.current_for(organization.id)
        raise Invalid, "No early-access window is open." unless window

        end_window!(window, actor, reason)
        audit!(actor, organization, END_ACTION, window, { reason: reason })
        window
      end
      DemoExpiry.call(organization_ids: [ organization.id ])
      window
    end

    # Ends an open window inside the caller's transaction.
    def end_window!(window, actor, reason)
      window.update!(ended_at: Time.current, ended_by: actor, end_reason: reason.to_s.first(EmployeeAppSwitch::REASON_MAX))
    end

    def authorize!(actor, organization)
      fresh = User.find_by(id: actor&.id)
      allowed = fresh && StaffRolePolicy.allowed?(fresh, :manage_employee_app_switch) && fresh.payroll_access_allowed? &&
        (fresh.super_admin? || fresh.organization_id == organization.id)
      raise Forbidden, "Only organization admins can change demo early access." unless allowed
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      return unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(value)
    rescue Date::Error
      nil
    end

    def parse_ids(values)
      ids = Array(values).map { |value| value.to_s.match?(/\A[1-9]\d{0,18}\z/) ? value.to_i : nil }
      if ids.empty? || ids.include?(nil) || ids.uniq.size != ids.size || ids.size > EmployeeAppEarlyAccessWindow::MAX_COMPANIES
        raise Invalid, "Choose one or #{EmployeeAppEarlyAccessWindow::MAX_COMPANIES} demo companies."
      end

      ids.sort
    end

    def audit!(actor, organization, action, window, metadata)
      record = lambda do
        AuditLog.record!(
          user: actor, organization_id: organization.id, company_id: nil, action: action,
          record_type: "EmployeeAppEarlyAccessWindow", record_id: window.id, subject_name: organization.name,
          event_category: "security", metadata: metadata
        )
      end
      TenantScope.current ? record.call : TenantScope.as_system(reason: "Record an employee app early-access change", &record)
    end
  end
end
