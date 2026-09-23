# frozen_string_literal: true

class CheckPrintGenerationJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(generation_id)
    generation = CheckPrintGeneration.find(generation_id)
    return unless generation.begin_processing!(job_id: job_id)

    CheckPrintRunGenerationService.new(
      pay_period: generation.pay_period,
      actor: generation.requested_by,
      payroll_item_ids: generation.payroll_item_ids,
      non_employee_check_ids: generation.non_employee_check_ids,
      starting_slot: generation.starting_slot,
      printer_profile_id: generation.printer_profile_id,
      printer_profile_lock_version: generation.printer_profile_lock_version,
      ip_address: generation.request_ip,
      generation: generation,
      progress: ->(phase, completed_items = nil) do
        generation.advance!(phase, completed_items: completed_items || generation.completed_items)
      end
    ).call
  rescue CheckPrintRunSelectionVerifier::StaleSelectionError, ArgumentError, ActiveRecord::RecordInvalid => e
    generation&.fail_safely!(
      code: "source_changed",
      message: e.message
    )
  rescue StandardError => e
    Rails.logger.error(
      "[CheckPrintGenerationJob] generation=#{generation_id} #{e.class}: #{e.message}"
    )
    generation&.fail_safely!(
      code: "generation_failed",
      message: "The package could not be generated. No checks were marked printed. Review the selection and try again."
    )
  end
end
