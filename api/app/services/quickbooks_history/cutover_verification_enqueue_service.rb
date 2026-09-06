# frozen_string_literal: true

module QuickbooksHistory
  class CutoverVerificationEnqueueService
    PENDING_RETRY_AFTER = 15.minutes
    Result = Struct.new(:review, :enqueued, keyword_init: true)

    def initialize(batch:, actor:)
      @batch = batch
      @actor = actor
    end

    def call
      ensure_authorized!
      CutoverVerificationService.ensure_supported_importer_version!(batch.importer_version)
      review, should_enqueue = prepare_pending_review!
      return Result.new(review: review, enqueued: false) unless should_enqueue

      enqueue!(review)
      Result.new(review: review, enqueued: true)
    end

    private

    attr_reader :batch, :actor

    def ensure_authorized!
      authorized = actor&.payroll_access_allowed? && actor.can_access_company?(batch.company_id) &&
        StaffRolePolicy.allowed?(actor, :manage_client_configuration)
      raise ArgumentError, "A manager or administrator with company access is required" unless authorized
      raise ArgumentError, "Apply the historical import before verifying cutover readiness" unless batch.reload.applied?
    end

    def prepare_pending_review!
      batch.with_lock do
        batch.reload
        raise ArgumentError, "Apply the historical import before verifying cutover readiness" unless batch.applied?

        review = batch.historical_import_cutover_review || batch.build_historical_import_cutover_review(company: batch.company)
        raise ArgumentError, "The approved cutover review is sealed" if review.approved?
        if review.pending? && review.verification_started_at.present? &&
           review.verification_started_at > PENDING_RETRY_AFTER.ago
          return [ review, false ]
        end

        review.assign_attributes(
          status: "pending",
          evidence: {},
          evidence_digest: nil,
          verification_started_at: Time.current,
          verification_error: nil,
          verified_at: nil,
          verified_by: nil,
          exception_dispositions: {},
          attestations: {},
          approval_notes: nil,
          approval_acknowledgement: nil,
          approved_at: nil,
          approved_by: nil
        )
        review.save!
        record_audit!(review, "historical_imports#queue_cutover_verification")
        [ review, true ]
      end
    end

    def enqueue!(review)
      verification_token = review.verification_started_at.iso8601(6)
      CutoverVerificationJob.perform_later(batch.id, actor.id, verification_token)
    rescue StandardError => e
      mark_enqueue_failed!(review, verification_token)
      Rails.logger.error("Historical cutover verification enqueue failed for batch #{batch.id}: #{e.class}: #{e.message}")
      raise ArgumentError, "Cutover verification could not be queued"
    end

    def mark_enqueue_failed!(review, verification_token)
      review.with_lock do
        return unless review.pending? && review.verification_started_at&.iso8601(6) == verification_token

        review.update!(status: "failed", verification_error: "Cutover verification could not be queued. Try again.")
        record_audit!(review, "historical_imports#cutover_verification_failed")
      end
    end

    def record_audit!(review, action)
      AuditLog.record!(
        user: actor,
        organization_id: batch.company.organization_id,
        company_id: batch.company_id,
        action: action,
        record_type: "historical_import_cutover_reviews",
        record_id: review.id,
        subject_name: batch.source_label,
        metadata: {
          historical_import_batch_id: batch.id,
          status: review.status,
          importer_version: batch.importer_version
        }
      )
    end
  end
end
