# frozen_string_literal: true

module QuickbooksHistory
  class CutoverVerificationJob < ApplicationJob
    queue_as :default

    def perform(batch_id, actor_id, verification_started_at)
      batch = HistoricalImportBatch.find(batch_id)
      review = batch.historical_import_cutover_review
      return unless current_attempt?(review, verification_started_at)

      actor = User.find(actor_id)
      CutoverVerificationService.new(
        batch: batch,
        actor: actor,
        expected_verification_started_at: verification_started_at
      ).call
    rescue CutoverVerificationService::StaleVerificationAttempt
      nil
    rescue StandardError => e
      persist_failure(batch_id, actor_id, verification_started_at, e)
    end

    private

    def persist_failure(batch_id, actor_id, verification_started_at, error)
      Rails.logger.error(
        "Historical cutover verification failed for batch #{batch_id}: " \
        "#{error.class} job_id=#{job_id}"
      )
      batch = HistoricalImportBatch.find_by(id: batch_id)
      review = batch&.historical_import_cutover_review
      return unless review

      review.with_lock do
        return unless current_attempt?(review, verification_started_at)

        review.update!(
          status: "failed",
          verification_error: "Cutover verification could not be completed. Review the source files and try again."
        )
        actor = User.find_by(id: actor_id)
        AuditLog.record!(
          user: actor,
          organization_id: batch.company.organization_id,
          company_id: batch.company_id,
          action: "historical_imports#cutover_verification_failed",
          record_type: "historical_import_cutover_reviews",
          record_id: review.id,
          subject_name: batch.source_label,
          metadata: {
            historical_import_batch_id: batch.id,
            status: review.status,
            error_class: error.class.name
          }
        )
      end
    rescue StandardError => persistence_error
      Rails.logger.error(
        "Historical cutover verification failure could not be persisted for batch #{batch_id}: " \
        "#{persistence_error.class} job_id=#{job_id}"
      )
    end

    def current_attempt?(review, verification_started_at)
      review&.pending? && review.verification_started_at&.iso8601(6) == verification_started_at
    end
  end
end
