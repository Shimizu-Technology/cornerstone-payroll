# frozen_string_literal: true

class StaffRolePolicy
  DELEGATABLE_CAPABILITIES = %i[manage_client_configuration manage_client_check_settings manage_client_administration].freeze
  ROLE_ONLY_CAPABILITIES = %i[manage_source_delegations manage_payroll_go_live_setup].freeze

  CAPABILITY_ROLES = {
    manage_source_delegations: %w[super_admin org_admin admin manager],
    manage_payroll_go_live_setup: %w[super_admin org_admin admin manager],
    staff_workspace: %w[super_admin org_admin admin manager accountant],
    payroll_operations: %w[super_admin org_admin admin manager accountant],
    manage_payroll_fields: %w[super_admin org_admin admin manager accountant],
    use_printer_profiles: %w[super_admin org_admin admin manager accountant],
    create_printer_profiles: %w[super_admin org_admin admin manager accountant],
    manage_printer_profile_library: %w[super_admin org_admin admin manager],
    manage_client_check_settings: %w[super_admin org_admin admin manager],
    view_record_activity: %w[super_admin org_admin admin manager accountant],
    manage_filing_review: %w[super_admin org_admin admin manager accountant],
    view_audit_history: %w[super_admin org_admin admin accountant],
    manage_client_configuration: %w[super_admin org_admin admin manager],
    manage_client_administration: %w[super_admin org_admin admin],
    manage_own_aire_account_link: %w[super_admin org_admin admin manager accountant],
    manage_historical_time_reconciliation: %w[super_admin org_admin admin manager accountant],
    manage_organization: %w[super_admin org_admin admin],
    manage_platform: %w[super_admin]
  }.freeze

  CAPABILITY_ERRORS = {
    manage_source_delegations: "Manager or admin access required",
    manage_payroll_go_live_setup: "Manager or admin access required",
    staff_workspace: "Staff access required",
    payroll_operations: "Payroll operations access required",
    manage_payroll_fields: "Payroll field management access required",
    use_printer_profiles: "Printer profile access required",
    create_printer_profiles: "Printer profile creation access required",
    manage_printer_profile_library: "Printer profile library management access required",
    manage_client_check_settings: "Manager, admin, or Client management access required",
    view_record_activity: "Record activity access required",
    manage_filing_review: "Filing review access required",
    view_audit_history: "Admin or accountant access required",
    manage_client_configuration: "Manager, admin, or Client management access required",
    manage_client_administration: "Admin access required or Client management for this client",
    manage_own_aire_account_link: "Payroll staff access required to connect your own AIRE account",
    manage_historical_time_reconciliation: "Historical time reconciliation access required",
    manage_organization: "Admin access required",
    manage_platform: "Super admin access required"
  }.freeze

  CONTROLLER_CAPABILITIES = {
    "api/v1/admin/time_tracking_imports" => :payroll_operations,
    "api/v1/admin/time_tracking_source_health" => :payroll_operations,
    "api/v1/admin/employee_hours_evidence" => :payroll_operations,
    "api/v1/admin/organizations" => :manage_platform,
    "api/v1/admin/users" => :manage_organization,
    "api/v1/admin/user_invitations" => :manage_organization,
    "api/v1/admin/company_assignments" => :manage_organization,
    "api/v1/admin/audit_logs" => :view_audit_history,
    "api/v1/admin/record_activities" => :view_record_activity,
    "api/v1/admin/historical_imports" => :payroll_operations,
    "api/v1/admin/historical_reports" => :payroll_operations,
    "api/v1/admin/payroll_history" => :payroll_operations,
    "api/v1/admin/imported_pay_periods" => :payroll_operations,
    "api/v1/admin/payroll_go_live" => :payroll_operations,
    "api/v1/admin/payroll_filing_responsibilities" => :payroll_operations,
    "api/v1/admin/payroll_filing_records" => :payroll_operations,
    "api/v1/admin/payroll_liability_center" => :payroll_operations,
    "api/v1/admin/check_register" => :payroll_operations,
    "api/v1/admin/payroll_final_records" => :payroll_operations,
    "api/v1/admin/tax_configs" => :manage_organization,
    "api/v1/admin/annual_retirement_limits" => :payroll_operations,
    "api/v1/admin/employee_retirement_year_inputs" => :payroll_operations,
    "api/v1/admin/employee_retirement_elections" => :payroll_operations,
    "api/v1/admin/invoices" => :manage_organization,
    "api/v1/admin/invoice_billing_profiles" => :manage_organization,
    "api/v1/admin/invoice_chat_sessions" => :manage_organization,
    "api/v1/admin/invoice_credit_notes" => :manage_organization,
    "api/v1/admin/invoice_payments" => :manage_organization,
    "api/v1/admin/invoice_receivables" => :manage_organization,
    "api/v1/admin/invoice_recipients" => :manage_organization
  }.freeze

  ACTION_CAPABILITIES = {
    "api/v1/admin/pay_periods#corrected_hours" => :payroll_operations,
    "api/v1/admin/pay_periods#connect_corrected_hours" => :payroll_operations,
    "api/v1/admin/annual_retirement_limits#create" => :manage_platform,
    "api/v1/admin/annual_retirement_limits#update" => :manage_platform,
    "api/v1/admin/employee_retirement_year_inputs#create" => :manage_client_configuration,
    "api/v1/admin/employee_retirement_elections#create" => :manage_client_configuration,
    "api/v1/admin/companies#create" => :manage_organization,
    "api/v1/admin/companies#migration_rehearsal_preview" => :manage_organization,
    "api/v1/admin/companies#create_migration_rehearsal" => :manage_organization,
    "api/v1/admin/companies#retry_migration_rehearsal" => :manage_organization,
    "api/v1/admin/companies#training_replay_preview" => :manage_organization,
    "api/v1/admin/companies#create_training_replay" => :manage_organization,
    "api/v1/admin/companies#retry_training_replay" => :manage_organization,
    "api/v1/admin/companies#test_workspace_preview" => :manage_organization,
    "api/v1/admin/companies#create_test_workspace" => :manage_organization,
    "api/v1/admin/companies#retry_test_workspace" => :manage_organization,
    "api/v1/admin/companies#archive_test_workspace" => :manage_organization,
    "api/v1/admin/companies#restore_test_workspace" => :manage_organization,
    "api/v1/admin/companies#migration_promotion_preview" => :manage_organization,
    "api/v1/admin/companies#create_migration_promotion_backup" => :manage_organization,
    "api/v1/admin/companies#apply_migration_promotion" => :manage_organization,
    "api/v1/admin/time_tracking_sources#create" => :manage_organization,
    "api/v1/admin/time_tracking_sources#update" => :manage_organization,
    "api/v1/admin/time_tracking_sources#destroy" => :manage_organization,
    "api/v1/admin/time_tracking_sources#test_connection" => :manage_organization,
    "api/v1/admin/time_tracking_sources#save_delegation" => :manage_source_delegations,
    "api/v1/admin/time_tracking_sources#destroy_delegation" => :manage_source_delegations,
    "api/v1/admin/time_tracking_sources#show_aire_account_link" => :manage_own_aire_account_link,
    "api/v1/admin/time_tracking_sources#create_aire_account_link" => :manage_own_aire_account_link,
    "api/v1/admin/time_tracking_sources#destroy_aire_account_link" => :manage_own_aire_account_link,
    "api/v1/admin/pay_component_tax_rules#create" => :manage_organization,
    "api/v1/admin/pay_component_tax_rules#update" => :manage_organization,
    "api/v1/admin/pay_schedule_settings#update" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_calendars#publish" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_calendars#retry_delivery" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_cockpits#approve_time_entry" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_cockpits#approve_time_entry_overtime" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_cockpits#correct_time_entry" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_cockpits#pay_late_hours" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_cockpits#retry_late_hours" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_cockpits#route_settlement_case" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_cockpits#confirm_employee_mapping" => :manage_client_configuration,
    "api/v1/admin/aire_payroll_cockpits#create_manual_allocation" => :manage_historical_time_reconciliation,
    "api/v1/admin/aire_payroll_cockpits#retry_manual_allocation" => :manage_historical_time_reconciliation,
    "api/v1/admin/aire_payroll_cockpits#payment_evidence" => :manage_historical_time_reconciliation,
    "api/v1/admin/aire_payroll_cockpits#create_payment_attestation" => :manage_historical_time_reconciliation,
    "api/v1/admin/aire_payroll_cockpits#retract_payment_attestation" => :manage_historical_time_reconciliation,
    "api/v1/admin/aire_payroll_cockpits#resolve_payment_attestation" => :manage_historical_time_reconciliation,
    "api/v1/admin/aire_payroll_cockpits#retry_payment_resolution" => :manage_historical_time_reconciliation,
    "api/v1/admin/aire_payroll_cockpits#finalize" => :manage_client_configuration,
    "api/v1/admin/payroll_go_live#preview_setup" => :manage_payroll_go_live_setup,
    "api/v1/admin/payroll_go_live#apply_setup" => :manage_platform,
    "api/v1/admin/payroll_filing_responsibilities#upsert" => :manage_filing_review,
    "api/v1/admin/payroll_filing_records#create_event" => :manage_filing_review,
    "api/v1/admin/checks#reverse_paycheck" => :payroll_operations,
    "api/v1/admin/non_employee_checks#mark_paid" => :payroll_operations,
    "api/v1/admin/payroll_items#update_payment_method" => :payroll_operations,
    "api/v1/admin/pay_periods#promoted_payment_preview" => :manage_organization,
    "api/v1/admin/pay_periods#prepare_promoted_payment" => :manage_organization,
    "api/v1/admin/pay_periods#adopt_confirmed_workweek" => :manage_client_configuration,
    "api/v1/admin/payroll_fields#create" => :manage_payroll_fields,
    "api/v1/admin/payroll_fields#update" => :manage_payroll_fields,
    "api/v1/admin/payroll_fields#destroy" => :manage_payroll_fields,
    "api/v1/admin/employee_payroll_fields#create_personal" => :payroll_operations,
    "api/v1/admin/employee_payroll_fields#create_and_assign" => :manage_payroll_fields,
    "api/v1/admin/employee_payroll_fields#pay_item" => :manage_payroll_fields,
    "api/v1/admin/payroll_reminder_configs#update" => :manage_client_configuration,
    "api/v1/admin/payroll_reminder_configs#test" => :manage_client_configuration,
    "api/v1/admin/checks#update_check_settings" => :manage_client_check_settings,
    "api/v1/admin/checks#update_next_check_number" => :manage_client_check_settings,
    "api/v1/admin/printer_profiles#create" => :create_printer_profiles,
    "api/v1/admin/printer_profiles#clone" => :create_printer_profiles,
    "api/v1/admin/printer_profiles#apply" => :use_printer_profiles,
    "api/v1/admin/printer_profiles#apply_to_all_companies" => :manage_printer_profile_library,
    "api/v1/admin/printer_profiles#clear_active" => :use_printer_profiles,
    "api/v1/admin/printer_profile_selections#update" => :use_printer_profiles,
    "api/v1/admin/printer_profile_selections#destroy" => :use_printer_profiles,
    "api/v1/admin/employee_change_requests#index" => :manage_client_configuration,
    "api/v1/admin/employee_change_requests#show" => :manage_client_configuration,
    "api/v1/admin/employee_change_requests#approve" => :manage_client_configuration,
    "api/v1/admin/employee_change_requests#reject" => :manage_client_configuration,
    "api/v1/admin/employee_intake_settings#update" => :manage_client_administration,
    "api/v1/admin/reports#w2_gu_mark_ready" => :manage_client_administration,
    "api/v1/admin/employees#review_intake_exception" => :manage_client_configuration,
    "api/v1/admin/employees#terminate" => :manage_client_configuration,
    "api/v1/admin/employees#reactivate" => :manage_client_configuration,
    "api/v1/admin/employees#transition_tax_classification" => :manage_platform,
    "api/v1/admin/employee_work_profiles#create" => :manage_client_configuration,
    "api/v1/admin/historical_imports#preview" => :manage_client_configuration,
    "api/v1/admin/historical_imports#apply" => :manage_client_configuration,
    "api/v1/admin/historical_imports#lock" => :manage_client_configuration,
    "api/v1/admin/historical_imports#verify_source_files" => :manage_client_configuration,
    "api/v1/admin/historical_imports#download_source_file" => :manage_client_configuration,
    "api/v1/admin/historical_imports#verify_cutover" => :manage_client_configuration,
    "api/v1/admin/historical_imports#update_cutover_review" => :manage_client_configuration,
    "api/v1/admin/historical_imports#approve_cutover" => :manage_client_configuration,
    "api/v1/admin/historical_imports#download_cutover_evidence" => :payroll_operations,
    "api/v1/admin/historical_imports#archive_unlinked_workers" => :manage_client_configuration,
    "api/v1/admin/historical_imports#preview_client_bootstrap" => :manage_client_configuration,
    "api/v1/admin/historical_imports#apply_client_bootstrap" => :manage_client_configuration,
    "api/v1/admin/historical_imports#update_worker" => :manage_client_configuration,
    "api/v1/admin/historical_imports#preview_ytd_bridge" => :manage_client_configuration,
    "api/v1/admin/historical_imports#apply_ytd_bridge" => :manage_client_configuration,
    "api/v1/admin/historical_paycheck_adjustments#index" => :payroll_operations,
    "api/v1/admin/historical_paycheck_adjustments#preview" => :manage_client_configuration,
    "api/v1/admin/historical_paycheck_adjustments#create" => :manage_client_configuration,
    "api/v1/admin/historical_paycheck_adjustments#reverse" => :manage_client_configuration,
    "api/v1/admin/historical_paycheck_adjustments#event" => :manage_client_configuration
  }.freeze

  def self.capability_for(controller_path:, action_name:)
    ACTION_CAPABILITIES["#{controller_path}##{action_name}"] || CONTROLLER_CAPABILITIES[controller_path]
  end

  def self.allowed?(user, capability, company: nil)
    return false unless user

    return true if CAPABILITY_ROLES.fetch(capability).include?(user.role)
    return false unless DELEGATABLE_CAPABILITIES.include?(capability) && company

    client_management_allowed?(user, company)
  end

  # Never use a memoized user, company, assignment collection or home-company
  # fallback to establish a delegated privilege. Revocation takes effect on the
  # next check, including service checks made after a request was authorized.
  def self.client_management_allowed?(user, company)
    return false unless user&.accountant? && company

    User.uncached do
      actor = User.find_by(id: user&.id)
      target = Company.includes(:organization).find_by(id: company&.id)
      next false unless actor&.accountant? && actor.payroll_access_allowed? &&
        target&.active? && target.organization&.active? && target.live_payroll? &&
        target.test_workspace_archived_at.nil? && actor.organization_id == target.organization_id

      CompanyAssignment.active_access.exists?(user_id: actor.id, company_id: target.id, client_management: true)
    end
  end

  # Historical approvals are separate from source/calendar configuration and
  # must also respect each accountant or manager's assigned client scope.
  def self.historical_reconciliation_allowed?(user, company)
    user.present? && company.present? && allowed?(user, :manage_historical_time_reconciliation) &&
      user.payroll_access_allowed? && company.active? && company.organization.active? &&
      company.test_workspace_archived_at.nil? && user.accessible_company_ids.include?(company.id)
  end

  # Connecting an operator's own AIRE identity does not grant source setup.
  def self.own_aire_account_link_allowed?(user, company)
    user.present? && company.present? && allowed?(user, :manage_own_aire_account_link) &&
      user.payroll_access_allowed? && company.active? && company.organization.active? &&
      company.test_workspace_archived_at.nil? && user.accessible_company_ids.include?(company.id)
  end

  def self.capabilities_for(user, company: nil)
    capabilities = (CAPABILITY_ROLES.keys - ROLE_ONLY_CAPABILITIES).select { |capability| allowed?(user, capability) }
    capabilities |= DELEGATABLE_CAPABILITIES if company && client_management_allowed?(user, company)
    capabilities.map(&:to_s)
  end

  def self.error_message(capability)
    CAPABILITY_ERRORS.fetch(capability)
  end
end
