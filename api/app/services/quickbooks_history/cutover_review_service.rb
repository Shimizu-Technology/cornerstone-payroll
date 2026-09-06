# frozen_string_literal: true

module QuickbooksHistory
  class CutoverReviewService
    def initialize(review:, actor:)
      @review = review
      @actor = actor
    end

    def save!(exception_dispositions:, attestations:, approval_notes:)
      ensure_authorized!
      review.with_lock do
        raise ArgumentError, "Run cutover verification before completing the checklist" unless review.status == "verified"

        review.update!(
          exception_dispositions: normalized_dispositions(exception_dispositions),
          attestations: normalized_attestations(attestations),
          approval_notes: approval_notes.to_s.strip.presence
        )
        record_audit!("historical_imports#save_cutover_review")
      end
      review
    end

    def approve!(acknowledgement:)
      ensure_authorized!
      review.with_lock do
        return review if review.approved?
        unless review.historical_import_batch.reload.applied?
          raise ArgumentError, "The historical import must remain applied until cutover approval"
        end
        raise ArgumentError, "Complete every cutover check and exception decision before approval" unless review.ready_for_approval?
        if acknowledgement.to_s != HistoricalImportCutoverReview::APPROVAL_ACKNOWLEDGEMENT
          raise ArgumentError, "Confirm the final QuickBooks cutover acknowledgement"
        end

        review.update!(
          status: "approved",
          approval_acknowledgement: acknowledgement,
          approved_by: actor,
          approved_at: Time.current
        )
        record_audit!("historical_imports#approve_cutover")
      end
      review
    end

    private

    attr_reader :review, :actor

    def ensure_authorized!
      batch = review.historical_import_batch
      authorized = actor.present? && actor.can_access_company?(batch.company_id) &&
        StaffRolePolicy.allowed?(actor, :manage_client_configuration)
      return if authorized

      raise ArgumentError, "A manager or administrator with company access is required"
    end

    def normalized_dispositions(value)
      allowed = Array(review.evidence.to_h["exceptions"]).pluck("key")
      value.to_h.stringify_keys.slice(*allowed).to_h do |key, disposition|
        normalized = disposition.to_s.strip
        raise ArgumentError, "Exception decisions must be 1,000 characters or fewer" if normalized.length > 1_000

        [ key, normalized ]
      end
    end

    def normalized_attestations(value)
      source = value.to_h.stringify_keys
      HistoricalImportCutoverReview::ATTESTATIONS.keys.to_h do |key|
        [ key, ActiveModel::Type::Boolean.new.cast(source[key]) ]
      end
    end

    def record_audit!(action)
      batch = review.historical_import_batch
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
          evidence_digest: review.evidence_digest,
          exceptions_complete: review.exceptions_complete?,
          attestations_complete: review.attestations_complete?
        }
      )
    end
  end
end
