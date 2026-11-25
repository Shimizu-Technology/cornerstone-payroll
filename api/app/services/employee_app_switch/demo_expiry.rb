# frozen_string_literal: true

module EmployeeAppSwitch
  # Makes the demo early-access rule stop applying on its own. While the
  # database doesn't enforce row-level security, a demo company that no
  # in-effect window covers (it expired, was ended, or no longer names the
  # company) has its employee app switches turned off and audited. Once the
  # database enforces RLS, demos follow regular readiness and this does
  # nothing. Real companies are never touched.
  module DemoExpiry
    ACTION = "employee_app_switch#demo_early_access_closed"
    REASON = "Demo early access no longer applies and the database doesn't enforce row-level security yet"

    module_function

    def call(organization_ids: nil, database_state: -> { Readiness.database_state }, today: PayrollBusinessClock.today)
      return [] if database_state.call[:enforced]

      companies = Company.demo.order(:id)
      companies = companies.where(organization_id: organization_ids) if organization_ids
      companies.to_a.filter_map do |company|
        close!(company, today)
      rescue StandardError => error
        # One company's failure must not stop the sweep for the rest.
        Rails.logger.error("[EmployeeAppSwitch::DemoExpiry] company=#{company.id} #{error.class}")
        nil
      end
    end

    def close!(company, today)
      company.with_lock do
        window = EmployeeAppEarlyAccessWindow.current_for(company.organization_id)
        next if window&.covers?(company, today: today)

        open = switches_on_from(company, today)
        next if open.empty?

        ProfileWriter.apply!(company: company, actor: nil, values: KEYS.index_with(false), reason: REASON, today: today)
        AuditLog.record!(
          actor: AuditActor.system_job(name), user: nil, organization_id: company.organization_id, company_id: company.id,
          action: ACTION, record_type: "Company", record_id: company.id, subject_name: company.name,
          event_category: "security", metadata: { turned_off: open, early_access_window_id: window&.id, reason: REASON }.compact
        )
        { company_id: company.id, turned_off: open }
      end
    end

    # Switches on today or in any later scheduled version.
    def switches_on_from(company, today)
      profiles = company.client_operating_profiles.where("ends_on IS NULL OR ends_on >= ?", today).order(:effective_on, :id)
      KEYS.select do |key|
        profiles.any? { |profile| (key == MASTER ? profile.employee_portal_enabled : profile.option_value(key)) == true }
      end
    end
  end
end
