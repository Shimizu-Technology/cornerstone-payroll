# frozen_string_literal: true

require "set"

# Milestone 3 build plan §2.1, plus employee notes and payroll history review.
module RlsTables
  RLS_PROTECTED_TABLES = %w[
    admin_overrides aire_history_operations aire_history_reviews aire_payroll_calendar_periods
    aire_payroll_cutoff_overrides aire_payroll_entry_acknowledgements
    aire_verified_history_rollout_receipts audit_logs check_events check_print_generations
    check_print_runs check_reconciliation_events check_signoff_sheets
    check_supersession_rollout_approvals client_documents client_operating_profiles
    client_portal_messages client_portal_threads company_help_contacts company_pay_schedules company_workweeks
    company_ytd_totals daily_time_records deduction_types delivery_consents demo_shape_conversions department_ytd_totals departments
    direct_deposit_payment_confirmations employee_account_links employee_app_activations employee_app_clerk_revocations
    employee_change_requests employee_compensation_changes employee_configuration_review_resolutions employee_contact_changes_to_confirm employee_deductions
    employee_document_notices employee_document_requirement_events employee_document_requirements employee_documents employee_email_change_notices employee_emergency_contacts employee_loans employee_notes
    employee_payroll_fields employee_retirement_elections employee_retirement_year_inputs
    employee_status_events employee_tipped_occupations employee_w4_elections employee_wage_rate_versions
    employee_wage_rates employee_work_profiles employee_year_fica_source_reviews employee_ytd_totals
    employees form500_filings form_1099_filing_readinesses general_transmittal_artifacts
    general_transmittal_items general_transmittals historical_client_bootstraps
    historical_employee_ytd_balances historical_import_batches historical_import_cutover_reviews
    historical_import_source_files historical_pay_periods historical_paycheck_adjustment_events
    historical_paycheck_adjustments historical_paycheck_fica_basis_proofs historical_paychecks
    historical_tax_wage_reports historical_workers historical_ytd_bridges loan_transactions
    non_employee_check_edits non_employee_check_line_items non_employee_check_supersessions
    non_employee_checks pay_component_tax_rules pay_period_correction_events
    pay_period_excluded_employees pay_periods payroll_entry_resolutions payroll_field_definitions
    payroll_filing_events payroll_filing_records payroll_filing_responsibilities payroll_go_live_reviews
    payroll_history_review_items payroll_imports payroll_intake_documents payroll_intake_rows
    payroll_intake_sessions payroll_item_deductions payroll_item_earnings payroll_item_fica_basis_proofs
    payroll_item_bridge_overlap_dispositions payroll_item_field_entries payroll_item_legacy_dispositions payroll_items
    payroll_liability_check_allocations payroll_liability_entries payroll_liability_obligation_due_dates
    payroll_liability_postings payroll_parallel_run_reviews payroll_reminder_configs
    payroll_reminder_logs payroll_review_packages payroll_standing_changes payroll_submission_documents
    payroll_submission_drafts payroll_submission_imports payroll_submission_periods
    payroll_submission_status_events payroll_submissions payroll_time_allocations portal_file_requests
    portal_message_attachments portal_notification_deliveries portal_notification_events
    portal_notification_recipients portal_upload_cleanups prior_provider_history_drafts
    prior_provider_history_onboardings punch_entries quarterly_compliance_packets
    time_tracking_category_mappings time_tracking_classification_reconciliations
    time_tracking_correction_dispositions time_tracking_delegations time_tracking_earning_choices
    time_tracking_employee_mappings time_tracking_entry_allocations
    time_tracking_financial_correction_links time_tracking_imports time_tracking_late_hours_runs
    time_tracking_legacy_identity_bindings time_tracking_manual_allocations time_tracking_sources
    timecards training_replay_benchmarks transmittals view_as_grants w2_filing_readinesses year_end_acknowledgements
  ].freeze

  # Child => [parent, foreign key]
  RLS_PARENT_PROTECTED_TABLES = {
    "aire_payroll_acknowledgements" => %w[time_tracking_imports time_tracking_import_id].freeze,
    "aire_payroll_calendar_publications" => %w[aire_payroll_calendar_periods aire_payroll_calendar_period_id].freeze,
    "aire_payroll_events" => %w[time_tracking_sources time_tracking_source_id].freeze,
    "historical_client_bootstrap_dispatches" => %w[historical_client_bootstraps historical_client_bootstrap_id].freeze,
    "payroll_submission_period_read_receipts" => %w[payroll_submission_periods payroll_submission_period_id].freeze,
    "portal_document_read_receipts" => %w[client_documents client_document_id].freeze,
    "portal_thread_read_receipts" => %w[client_portal_threads client_portal_thread_id].freeze,
    "quarterly_compliance_tasks" => %w[quarterly_compliance_packets quarterly_compliance_packet_id].freeze,
    "time_tracking_correction_receipts" => %w[time_tracking_correction_dispositions time_tracking_correction_disposition_id].freeze,
    "time_tracking_lock_rollout_selections" => %w[time_tracking_sources time_tracking_source_id].freeze
  }.freeze

  RLS_EXEMPT_TABLES = %w[
    cable_connection_tickets client_profitability_settings companies company_assignments
    employee_app_early_access_windows employee_placeholder_emails
    expense_artifacts expense_payments expense_vendors expenses filing_submitters finance_api_requests
    finance_api_tokens finance_books invoice_artifacts invoice_billing_profiles invoice_chat_messages
    invoice_chat_sessions invoice_credit_notes invoice_deliveries invoice_events invoice_line_items
    invoice_number_sequences invoice_payments invoice_recipients invoice_recurrences
    invoice_send_schedules invoices organizations portal_notification_preferences printer_profiles
    user_invitations user_printer_profile_selections user_sessions users work_hour_client_links
    work_hour_imports work_hour_rows work_hour_staff_links
  ].freeze

  RLS_GLOBAL_TABLES = %w[
    annual_retirement_limits annual_tax_configs delivery_disclosures email_provider_events
    employee_terms_versions filing_status_configs information_return_thresholds
    operational_queue_probes solid_queue_blocked_executions solid_queue_claimed_executions
    solid_queue_failed_executions solid_queue_jobs solid_queue_pauses solid_queue_processes
    solid_queue_ready_executions solid_queue_recurring_executions solid_queue_recurring_tasks
    solid_queue_scheduled_executions solid_queue_semaphores tax_brackets tax_config_audit_logs tax_tables
  ].freeze

  # Provisioned independently of the primary Rails schema.
  INFRASTRUCTURE_TABLES = %w[
    ar_internal_metadata schema_migrations solid_cache_entries solid_cable_messages staging_quarantines
  ].freeze

  RLS_SHARED_READ_TABLES = %w[pay_component_tax_rules].freeze

  PROTECTED_TABLES = (RLS_PROTECTED_TABLES + RLS_PARENT_PROTECTED_TABLES.keys).to_set.freeze
end
