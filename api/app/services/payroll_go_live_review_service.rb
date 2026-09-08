# frozen_string_literal: true

class PayrollGoLiveReviewService
  def initialize(review:, actor:)
    @review = review
    @actor = actor
  end

  def save!(attestations:, review_notes:)
    authorize_operations!
    raise ArgumentError, "Approved go-live evidence is sealed" if review.approved?

    review.update!(
      attestations: normalized_attestations(attestations),
      review_notes: review_notes.to_s.strip.presence
    )
    clear_stale_signoffs!
    audit!("payroll_go_live#save_review")
    review
  end

  def sign_technical!(acknowledgement:)
    raise ArgumentError, "A super administrator must complete technical signoff" unless StaffRolePolicy.allowed?(actor, :manage_platform)
    sign!(:technical, acknowledgement, PayrollGoLiveReview::TECHNICAL_ACKNOWLEDGEMENT)
  end

  def sign_operations!(acknowledgement:)
    allowed = actor&.payroll_access_allowed? && actor.can_access_company?(review.company_id) &&
      actor.role.in?(%w[org_admin admin manager])
    raise ArgumentError, "A Cornerstone manager or administrator must complete operations signoff" unless allowed
    sign!(:operations, acknowledgement, PayrollGoLiveReview::OPERATIONS_ACKNOWLEDGEMENT)
  end

  private

  attr_reader :review, :actor

  def authorize_operations!
    allowed = actor&.payroll_access_allowed? && actor.can_access_company?(review.company_id) &&
      StaffRolePolicy.allowed?(actor, :payroll_operations)
    raise ArgumentError, "Cornerstone payroll access is required" unless allowed
  end

  def sign!(kind, acknowledgement, expected)
    authorize_operations!
    raise ArgumentError, "Type #{expected} to confirm" unless acknowledgement == expected
    raise ArgumentError, PayrollGoLiveReadiness.new(review).blockers.join("; ") unless review.ready_for_signoff?
    other_actor_id = kind == :technical ? review.operations_signed_by_id : review.technical_signed_by_id
    raise ArgumentError, "Technical and operations signoff must be completed by different people" if other_actor_id == actor.id

    review.with_lock do
      review.update!(
        "#{kind}_signed_by" => actor,
        "#{kind}_signed_at" => Time.current
      )
      if review.technical_signed_at.present? && review.operations_signed_at.present?
        review.update!(status: "approved", approved_at: Time.current)
      end
    end
    audit!("payroll_go_live#sign_#{kind}")
    review
  end

  def normalized_attestations(value)
    source = value.to_h.stringify_keys
    PayrollGoLiveReview::ATTESTATIONS.keys.to_h do |key|
      [ key, ActiveModel::Type::Boolean.new.cast(source[key]) || false ]
    end
  end

  def clear_stale_signoffs!
    return if review.technical_signed_at.blank? && review.operations_signed_at.blank?

    review.update_columns(
      technical_signed_by_id: nil,
      technical_signed_at: nil,
      operations_signed_by_id: nil,
      operations_signed_at: nil,
      updated_at: Time.current
    )
  end

  def audit!(action)
    AuditLog.record!(
      user: actor,
      organization_id: review.company.organization_id,
      company_id: review.company_id,
      action: action,
      record_type: "payroll_go_live_reviews",
      record_id: review.id,
      subject_name: review.company.name,
      metadata: {
        ready_for_signoff: review.ready_for_signoff?,
        technical_signed: review.technical_signed_at.present?,
        operations_signed: review.operations_signed_at.present?
      }
    )
  end
end
