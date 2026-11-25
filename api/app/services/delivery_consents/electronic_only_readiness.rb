# frozen_string_literal: true

module DeliveryConsents
  # Readiness rule for electronic-only delivery (M4-6, pilot decision D5).
  # Paper continues for everyone during the pilot; recording employee consent
  # never turns paper off until all four operational/legal gates pass.
  class ElectronicOnlyReadiness
    Check = Data.define(:key, :label, :passed, :detail)
    Result = Data.define(:kind, :checks) do
      def ready?
        checks.all?(&:passed)
      end

      def paper_required?
        !ready?
      end

      def blockers
        checks.reject(&:passed)
      end

      def as_json(*)
        {
          kind: kind,
          ready: ready?,
          paper_required: paper_required?,
          checks: checks.map { |check| { key: check.key.to_s, label: check.label, passed: check.passed, detail: check.detail } }
        }
      end
    end

    # Operational/legal gates stay false until verified in a dedicated follow-up PR
    # after counsel approval, Guam DRT response, M4-5 bounce tracking, and end-to-end
    # paper-on-withdrawal verification.
    DRT_ANSWERED = false
    BOUNCE_TRACKING_EXISTS = false
    PAPER_ON_WITHDRAWAL_VERIFIED = false

    def self.evaluate(
      kind:,
      disclosure: nil,
      drt_answered: DRT_ANSWERED,
      bounce_tracking_exists: BOUNCE_TRACKING_EXISTS,
      paper_on_withdrawal_verified: PAPER_ON_WITHDRAWAL_VERIFIED
    )
      normalized_kind = kind.to_s
      unless DeliveryDisclosure::KINDS.include?(normalized_kind)
        raise ArgumentError, "Unknown delivery consent kind: #{kind}"
      end

      current_disclosure = disclosure || DeliveryDisclosure.current_for(normalized_kind)
      disclosure_approved = current_disclosure&.approved? == true

      checks = [
        Check.new(
          key: :disclosure_approved,
          label: "Counsel-approved disclosure wording",
          passed: disclosure_approved,
          detail: disclosure_approved ? "Approved disclosure #{current_disclosure.version} is published." : "Draft wording is awaiting counsel approval."
        ),
        Check.new(
          key: :drt_answered,
          label: "Guam DRT response received",
          passed: drt_answered == true,
          detail: drt_answered == true ? "Guam DRT guidance has been recorded." : "Awaiting Guam DRT response on electronic furnishing."
        ),
        Check.new(
          key: :bounce_tracking_exists,
          label: "Email bounce tracking with 30-day paper fallback",
          passed: bounce_tracking_exists == true,
          detail: bounce_tracking_exists == true ? "Bounce tracking and mailed fallback are active." : "Email bounce tracking is not yet active."
        ),
        Check.new(
          key: :paper_on_withdrawal_verified,
          label: "Paper-on-withdrawal workflow verified",
          passed: paper_on_withdrawal_verified == true,
          detail: paper_on_withdrawal_verified == true ? "End-to-end paper fallback on withdrawal is verified." : "Paper-on-withdrawal operational verification is pending."
        )
      ].freeze

      Result.new(kind: normalized_kind, checks: checks)
    end

    # Paper delivery remains required unless ALL four electronic-only readiness
    # gates pass AND the employee has an active, non-withdrawn consent matching
    # the current approved disclosure.
    def self.paper_delivery_required?(company:, employee:, kind:, **overrides)
      current_disclosure = overrides[:disclosure] || DeliveryDisclosure.current_for(kind)
      readiness = evaluate(kind: kind, disclosure: current_disclosure, **overrides.except(:disclosure))
      return true unless readiness.ready?
      return true unless company && employee && current_disclosure&.approved?

      active_consent = DeliveryConsent.active
        .where(company_id: company.id, employee_id: employee.id, kind: kind.to_s)
        .order(given_at: :desc, id: :desc)
        .first
      !active_consent&.matches_disclosure?(current_disclosure)
    end
  end
end
