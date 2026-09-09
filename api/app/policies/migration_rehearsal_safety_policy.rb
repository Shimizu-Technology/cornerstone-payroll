# frozen_string_literal: true

class MigrationRehearsalSafetyPolicy
  BLOCKED_ACTIONS = {
    "api/v1/admin/pay_periods" => %w[
      commit void create_correction_run correct_pay_date generate_fit_check retry_tax_sync corrective_paychecks
    ],
    "api/v1/admin/check_numbers" => %w[update],
    "api/v1/admin/checks" => %w[batch_pdf mark_all_printed mark_printed mark_delivered void reprint update_check_number replace_check],
    "api/v1/admin/check_print_runs" => %w[create pdf confirm],
    "api/v1/admin/non_employee_checks" => %w[create update destroy mark_printed void_check batch_pdf mark_all_printed check_pdf voucher_pdf],
    "api/v1/admin/general_transmittals" => %w[generate_pdf artifact_pdf],
    "api/v1/admin/reports" => %w[
      start_quarterly_compliance_packet_workflow update_quarterly_compliance_packet_task
      quarterly_compliance_packet_official_form_download w2_gu_mark_ready
      transmittal_log_pdf full_print_package_pdf check_signoff_pdf
    ],
    "api/v1/admin/invoices" => %w[create update destroy issue record_delivery import update_status generate_pdf],
    "api/v1/admin/invoice_payments" => %w[create reverse],
    "api/v1/admin/invoice_credit_notes" => %w[create void]
  }.freeze

  def self.blocked?(controller_path:, action_name:)
    BLOCKED_ACTIONS.fetch(controller_path, []).include?(action_name)
  end
end
