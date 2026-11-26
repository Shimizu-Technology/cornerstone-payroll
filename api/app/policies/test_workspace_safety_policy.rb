# frozen_string_literal: true

class TestWorkspaceSafetyPolicy
  BLOCKED_ACTIONS = {
    "api/v1/admin/filing_submitters" => %w[update],
    # These records are shared across live companies, rather than copied into a workspace.
    "api/v1/admin/annual_retirement_limits" => %w[create update],
    "api/v1/admin/employee_contact_hygiene" => %w[mark_placeholder_email unmark_placeholder_email],
    "api/v1/admin/tax_configs" => %w[
      create update destroy activate verify replace_withholding update_filing_status update_brackets
    ],
    "api/v1/admin/pay_periods" => %w[
      commit void reopen_unpaid create_correction_run correct_pay_date generate_fit_check corrective_paychecks
    ],
    "api/v1/admin/time_tracking_imports" => %w[correction_confirm correction_delivery_retry],
    "api/v1/admin/check_numbers" => %w[update],
    "api/v1/admin/checks" => %w[batch_pdf mark_all_printed mark_printed mark_delivered void reprint update_check_number replace_check],
    "api/v1/admin/check_print_runs" => %w[create pdf confirm],
    "api/v1/admin/check_print_generations" => %w[create],
    "api/v1/admin/check_register" => %w[create_event],
    "api/v1/admin/non_employee_checks" => %w[
      create update destroy mark_printed void_check batch_pdf mark_all_printed check_pdf voucher_pdf mark_paid supersede_with_payroll_item
    ],
    "api/v1/admin/general_transmittals" => %w[generate_pdf artifact_pdf],
    "api/v1/admin/reports" => %w[
      start_quarterly_compliance_packet_workflow update_quarterly_compliance_packet_task
      quarterly_compliance_packet_official_form_download w2_gu_mark_ready w2_gu_efw2 w3ss_pdf form_1099_pub1220 form_1096_totals
      transmittal_log_pdf full_print_package_pdf check_signoff_sheet check_signoff_pdf
      w2_gu_copy_1_drt form_1099_nec_payer_record
    ],
    "api/v1/admin/year_end" => %w[form_1099_mark_ready],
    "api/v1/admin/payroll_filing_records" => %w[create_event],
    "api/v1/admin/invoices" => %w[create update destroy issue record_delivery import update_status generate_pdf],
    "api/v1/admin/invoice_payments" => %w[create reverse],
    "api/v1/admin/invoice_credit_notes" => %w[create void]
  }.freeze

  # A demo company works like a live client up to the point something would
  # leave the firm or touch its own numbers. It keeps the shared-config,
  # payment, commit and filing-transmission blocks above, but reviews,
  # previews, copies and checklist steps work as they do for a live client.
  # Integration and firm-finance prefixes stay closed (see blocked?).
  DEMO_ALLOWED_ACTIONS = {
    # A demo commits, voids and corrects its own simulated payroll. Liability
    # postings, FIT deposit checks and AIRE are skipped by company in the
    # services, so nothing reaches the firm's ledger or a provider.
    "api/v1/admin/pay_periods" => %w[commit void reopen_unpaid create_correction_run correct_pay_date corrective_paychecks],
    # Plain-paper checks only; preprinted bank stock refuses a demo.
    "api/v1/admin/checks" => %w[batch_pdf mark_all_printed mark_printed mark_delivered void reprint update_check_number replace_check],
    "api/v1/admin/check_print_runs" => %w[create pdf confirm],
    "api/v1/admin/check_print_generations" => %w[create],
    "api/v1/admin/check_register" => %w[create_event],
    "api/v1/admin/check_numbers" => %w[update],
    "api/v1/admin/general_transmittals" => %w[generate_pdf artifact_pdf],
    "api/v1/admin/reports" => %w[
      start_quarterly_compliance_packet_workflow update_quarterly_compliance_packet_task
      quarterly_compliance_packet_official_form_download w2_gu_mark_ready w3ss_pdf form_1096_totals
      transmittal_log_pdf full_print_package_pdf check_signoff_sheet check_signoff_pdf
      w2_gu_copy_1_drt form_1099_nec_payer_record
    ],
    "api/v1/admin/year_end" => %w[form_1099_mark_ready]
  }.freeze

  # Lifted for new-shape demo companies (live + demo flag). Legacy
  # test-workspace demos still have pre-migration DB triggers on these tables
  # until the Track B Migrate phase drops them, so they remain blocked while
  # legacy_demo is true.
  DEMO_LIVE_FLAG_ALLOWED_ACTIONS = {
    "api/v1/admin/pay_periods" => %w[generate_fit_check],
    "api/v1/admin/non_employee_checks" => %w[
      create update destroy mark_printed void_check batch_pdf mark_all_printed check_pdf voucher_pdf mark_paid supersede_with_payroll_item
    ],
    "api/v1/admin/payroll_filing_records" => %w[create_event]
  }.freeze

  # Electronic filing upload files a demo never produces outside DEPLOYMENT_ENV=local.
  DEMO_LOCAL_ONLY_EFILE_ACTIONS = {
    "api/v1/admin/reports" => %w[w2_gu_efw2 form_1099_pub1220 quarterly_compliance_packet_swica_ascii]
  }.freeze

  # Electronic filing files a demo never produces outside local mode, plus
  # org-wide refreshes. A practice copy keeps its existing access to SWICA;
  # EFW2 and Pub 1220 are blocked for every workspace.
  DEMO_BLOCKED_ACTIONS = {
    "api/v1/admin/reports" => %w[quarterly_compliance_packet_swica_ascii],
    # A refresh pulls the whole organization's Cornerstone Tax hours.
    "api/v1/admin/client_profitability" => %w[refresh]
  }.freeze

  # Firm-level organization administration is shared across live clients.
  # Only read-only inspection is allowed while a contained company is selected;
  # any mutation or admin invitation fails closed.
  ORGANIZATION_READ_ACTIONS = %w[index show company_transfer_preview].freeze

  # Firm books are shared live records even while a copied payroll client is
  # selected. New finance actions fail closed until reviewed as read-only.
  FINANCE_READ_ACTIONS = {
    "api/v1/admin/invoices" => %w[index show preview_pdf download_artifact],
    "api/v1/admin/invoice_receivables" => %w[show statement],
    "api/v1/admin/expenses" => %w[index show export download_artifact],
    "api/v1/admin/finance_overviews" => %w[show],
    "api/v1/admin/finance_books" => %w[index],
    "api/v1/admin/finance_api_tokens" => %w[index],
    "api/v1/admin/invoice_chat_sessions" => %w[index show],
    "api/v1/admin/invoice_send_schedules" => %w[index],
    "api/v1/admin/invoice_recurrences" => %w[index],
    "api/v1/admin/invoice_recipients" => %w[index show],
    "api/v1/admin/invoice_billing_profiles" => %w[index show sample_pdf],
    "api/v1/admin/expense_vendors" => %w[index]
  }.freeze

  def self.blocked?(controller_path:, action_name:, request_method: nil, demo: false, legacy_demo: false)
    if controller_path.start_with?("api/v1/admin/time_tracking_", "api/v1/admin/aire_")
      return false if request_method.in?(%w[GET HEAD])
      return !(controller_path == "api/v1/admin/time_tracking_sources" && action_name.in?(%w[index show]))
    end

    if controller_path == "api/v1/admin/organizations"
      return !ORGANIZATION_READ_ACTIONS.include?(action_name)
    end

    if controller_path.start_with?("api/v1/admin/invoice", "api/v1/admin/expense", "api/v1/admin/finance_")
      return !FINANCE_READ_ACTIONS.fetch(controller_path, []).include?(action_name)
    end

    if demo && DEMO_LOCAL_ONLY_EFILE_ACTIONS.fetch(controller_path, []).include?(action_name)
      return !LocalDeployment.local?
    end

    return true if demo && DEMO_BLOCKED_ACTIONS.fetch(controller_path, []).include?(action_name)
    return false if demo && DEMO_ALLOWED_ACTIONS.fetch(controller_path, []).include?(action_name)
    return false if demo && !legacy_demo && DEMO_LIVE_FLAG_ALLOWED_ACTIONS.fetch(controller_path, []).include?(action_name)

    BLOCKED_ACTIONS.fetch(controller_path, []).include?(action_name)
  end
end
