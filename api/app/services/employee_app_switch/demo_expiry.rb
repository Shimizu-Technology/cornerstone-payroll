# frozen_string_literal: true

module EmployeeAppSwitch
  # Reconciles the stored demo switches with the early-access rule. The rule
  # already applies at read time (CompanyFeatures closes a demo's app the
  # moment its window stops covering it); this sweep turns the stored
  # switches off too, revokes their activations and audits it. While the
  # database doesn't enforce row-level security, a demo company that no
  # in-effect window covers (it expired, was ended or retired, or no longer
  # names the company) is closed. Once the database enforces RLS, open
  # windows retire for good and demos follow regular readiness. Real
  # companies are never touched.
  module DemoExpiry
    ACTION = "employee_app_switch#demo_early_access_closed"
    REASON = "Demo early access no longer applies and the database doesn't enforce row-level security yet"

    module_function

    def call(organization_ids: nil, database_state: -> { Readiness.database_state }, today: PayrollBusinessClock.today)
      if database_state.call[:enforced]
        Enforcement.retire_windows!
        return []
      end

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

        open = EmployeeAppSwitch.on_anywhere(company, today: today)
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
  end
end
