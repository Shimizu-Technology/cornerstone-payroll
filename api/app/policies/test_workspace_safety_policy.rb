# frozen_string_literal: true

class TestWorkspaceSafetyPolicy
  BLOCKED_ACTIONS = {
    # These records are shared across live companies, rather than copied into a workspace.
    "api/v1/admin/annual_retirement_limits" => %w[create update],
    "api/v1/admin/pay_periods" => %w[
      commit void reopen_unpaid create_correction_run correct_pay_date generate_fit_check retry_tax_sync corrective_paychecks
    ],
    "api/v1/admin/time_tracking_imports" => %w[correction_confirm correction_delivery_retry],
    "api/v1/admin/check_numbers" => %w[update],
    "api/v1/admin/checks" => %w[batch_pdf mark_all_printed mark_printed mark_delivered void reprint update_check_number replace_check],
    "api/v1/admin/check_print_runs" => %w[create pdf confirm],
    "api/v1/admin/check_print_generations" => %w[create],
    "api/v1/admin/check_register" => %w[create_event],
    "api/v1/admin/non_employee_checks" => %w[create update destroy mark_printed void_check batch_pdf mark_all_printed check_pdf voucher_pdf],
    "api/v1/admin/general_transmittals" => %w[generate_pdf artifact_pdf],
    "api/v1/admin/reports" => %w[
      start_quarterly_compliance_packet_workflow update_quarterly_compliance_packet_task
      quarterly_compliance_packet_official_form_download w2_gu_mark_ready
      transmittal_log_pdf full_print_package_pdf check_signoff_sheet check_signoff_pdf
    ],
    "api/v1/admin/payroll_filing_records" => %w[create_event],
    "api/v1/admin/invoices" => %w[create update destroy issue record_delivery import update_status generate_pdf],
    "api/v1/admin/invoice_payments" => %w[create reverse],
    "api/v1/admin/invoice_credit_notes" => %w[create void]
  }.freeze

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
    "api/v1/admin/invoice_billing_profiles" => %w[index show],
    "api/v1/admin/expense_vendors" => %w[index]
  }.freeze

  def self.blocked?(controller_path:, action_name:)
    if controller_path.start_with?("api/v1/admin/invoice", "api/v1/admin/expense", "api/v1/admin/finance_")
      return !FINANCE_READ_ACTIONS.fetch(controller_path, []).include?(action_name)
    end

    BLOCKED_ACTIONS.fetch(controller_path, []).include?(action_name)
  end
end
