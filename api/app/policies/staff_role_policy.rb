# frozen_string_literal: true

class StaffRolePolicy
  CAPABILITY_ROLES = {
    staff_workspace: %w[super_admin org_admin admin manager accountant],
    payroll_operations: %w[super_admin org_admin admin manager accountant],
    view_audit_history: %w[super_admin org_admin admin accountant],
    manage_client_configuration: %w[super_admin org_admin admin manager],
    manage_organization: %w[super_admin org_admin admin],
    manage_platform: %w[super_admin]
  }.freeze

  CAPABILITY_ERRORS = {
    staff_workspace: "Staff access required",
    payroll_operations: "Payroll operations access required",
    view_audit_history: "Admin or accountant access required",
    manage_client_configuration: "Manager or admin access required",
    manage_organization: "Admin access required",
    manage_platform: "Super admin access required"
  }.freeze

  CONTROLLER_CAPABILITIES = {
    "api/v1/admin/organizations" => :manage_platform,
    "api/v1/admin/users" => :manage_organization,
    "api/v1/admin/user_invitations" => :manage_organization,
    "api/v1/admin/company_assignments" => :manage_organization,
    "api/v1/admin/audit_logs" => :view_audit_history,
    "api/v1/admin/historical_imports" => :view_audit_history,
    "api/v1/admin/tax_configs" => :manage_organization,
    "api/v1/admin/invoices" => :manage_organization,
    "api/v1/admin/invoice_billing_profiles" => :manage_organization,
    "api/v1/admin/invoice_chat_sessions" => :manage_organization,
    "api/v1/admin/invoice_credit_notes" => :manage_organization,
    "api/v1/admin/invoice_payments" => :manage_organization,
    "api/v1/admin/invoice_receivables" => :manage_organization,
    "api/v1/admin/invoice_recipients" => :manage_organization
  }.freeze

  ACTION_CAPABILITIES = {
    "api/v1/admin/companies#create" => :manage_organization,
    "api/v1/admin/time_tracking_sources#create" => :manage_organization,
    "api/v1/admin/time_tracking_sources#update" => :manage_organization,
    "api/v1/admin/time_tracking_sources#destroy" => :manage_organization,
    "api/v1/admin/time_tracking_sources#test_connection" => :manage_organization,
    "api/v1/admin/pay_component_tax_rules#create" => :manage_organization,
    "api/v1/admin/pay_component_tax_rules#update" => :manage_organization,
    "api/v1/admin/pay_schedule_settings#update" => :manage_client_configuration,
    "api/v1/admin/pay_periods#adopt_confirmed_workweek" => :manage_client_configuration,
    "api/v1/admin/payroll_fields#create" => :manage_client_configuration,
    "api/v1/admin/payroll_fields#update" => :manage_client_configuration,
    "api/v1/admin/payroll_fields#destroy" => :manage_client_configuration,
    "api/v1/admin/payroll_reminder_configs#update" => :manage_client_configuration,
    "api/v1/admin/payroll_reminder_configs#test" => :manage_client_configuration,
    "api/v1/admin/checks#update_check_settings" => :manage_client_configuration,
    "api/v1/admin/checks#update_next_check_number" => :manage_client_configuration,
    "api/v1/admin/printer_profiles#create" => :manage_client_configuration,
    "api/v1/admin/printer_profiles#update" => :manage_client_configuration,
    "api/v1/admin/printer_profiles#destroy" => :manage_client_configuration,
    "api/v1/admin/printer_profiles#apply" => :manage_client_configuration,
    "api/v1/admin/printer_profiles#apply_to_all_companies" => :manage_client_configuration,
    "api/v1/admin/printer_profiles#clear_active" => :manage_client_configuration,
    "api/v1/admin/employee_change_requests#index" => :manage_client_configuration,
    "api/v1/admin/employee_change_requests#show" => :manage_client_configuration,
    "api/v1/admin/employee_change_requests#approve" => :manage_client_configuration,
    "api/v1/admin/employee_change_requests#reject" => :manage_client_configuration,
    "api/v1/admin/employees#terminate" => :manage_client_configuration,
    "api/v1/admin/employees#reactivate" => :manage_client_configuration,
    "api/v1/admin/employees#transition_tax_classification" => :manage_platform,
    "api/v1/admin/employee_work_profiles#create" => :manage_client_configuration,
    "api/v1/admin/historical_imports#preview" => :manage_client_configuration,
    "api/v1/admin/historical_imports#apply" => :manage_client_configuration,
    "api/v1/admin/historical_imports#lock" => :manage_client_configuration,
    "api/v1/admin/historical_imports#update_worker" => :manage_client_configuration
  }.freeze

  def self.capability_for(controller_path:, action_name:)
    ACTION_CAPABILITIES["#{controller_path}##{action_name}"] || CONTROLLER_CAPABILITIES[controller_path]
  end

  def self.allowed?(user, capability)
    return false unless user

    CAPABILITY_ROLES.fetch(capability).include?(user.role)
  end

  def self.error_message(capability)
    CAPABILITY_ERRORS.fetch(capability)
  end
end
