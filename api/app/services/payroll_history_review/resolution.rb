# frozen_string_literal: true

module PayrollHistoryReview
  class Resolution
    class Conflict < StandardError; end
    class Forbidden < StandardError; end
    class Maintenance < StandardError; end

    def self.ensure_writable!(company)
      raise Maintenance, WriteMaintenance.payload.fetch(:error) if WriteMaintenance.enabled?
      raise Forbidden, "This workspace is read-only" if company.test_workspace_read_only?
    end

    def self.detection_actor
      AuditActor.system_job(PayrollHistoryReviewItem::DETECTION_ACTOR_NAME)
    end

    def initialize(company:, tax_year:, subject_key:, user:, actor:)
      @company, @tax_year, @subject_key, @user, @actor = company, tax_year, subject_key, user, actor
    end

    def resolve!(code:, reference:, expected_digest:, &authorize)
      unless reference.is_a?(String) && reference.strip.length.between?(10, 1000)
        raise ArgumentError, "Enter a review reference of 10–1000 characters"
      end

      transition(expected_digest, resolved: false, authorize: authorize) do |item|
        unless item.available_resolution_codes.include?(code)
          raise ArgumentError, "Choose a resolution code for this payroll history item"
        end

        item.update!(status: "resolved", resolution_code: code, resolution_reference: reference,
          resolved_by: @user, resolved_at: Time.current)
        self.class.audit!(item, action: "resolve", actor: @actor, metadata: item.attributes.slice(*PayrollHistoryReviewItem::RESOLUTION_FIELDS))
      end
    end

    def reopen!(reason:, expected_digest:, &authorize)
      unless reason.is_a?(String) && reason.strip.length.between?(1, 1000)
        raise ArgumentError, "Enter a reopening reason of 1–1000 characters"
      end

      transition(expected_digest, resolved: true, authorize: authorize) do |item|
        raise Conflict, "The saved proofs close this review item." if item.system_proven?

        self.class.reopen_item(item, reason: reason.strip, actor: @actor, digest: item.subject_digest, apply: true)
      end
    end

    def self.reopen_item(item, reason:, actor:, digest:, apply:)
      previous = item.attributes.slice(*PayrollHistoryReviewItem::RESOLUTION_FIELDS, "subject_digest")
      item.assign_attributes(PayrollHistoryReviewItem::RESOLUTION_FIELDS.index_with(nil).merge(
        status: "open", subject_digest: digest, reopened_at: Time.current))
      return unless apply

      item.save!
      audit!(item, action: "reopen", actor: actor, metadata: { reason: reason, previous_resolution: previous })
    end

    def self.prove_item(item, digest:, at:, apply:)
      previous = item.attributes.slice(*PayrollHistoryReviewItem::RESOLUTION_FIELDS, "subject_digest") if item.persisted?
      item.assign_attributes(status: "resolved", subject_digest: digest, resolution_code: PayrollHistoryReviewItem::PROVEN_CODE,
        resolution_reference: "Verified FICA basis proofs cover the legacy paychecks.", resolved_by: nil, resolved_at: at)
      return unless apply

      item.save!
      audit!(item, action: "resolve", actor: detection_actor,
        metadata: item.attributes.slice(*PayrollHistoryReviewItem::RESOLUTION_FIELDS).merge(previous_resolution: previous))
    end

    def self.audit!(item, action:, actor:, metadata:)
      AuditLog.record!(actor: actor, organization_id: item.company.organization_id, company_id: item.company_id,
        action: "payroll_history_review##{action}", record_type: item.class.name, record_id: item.id,
        metadata: metadata.merge(tax_year: item.tax_year, subject_type: item.subject_type, subject_digest: item.subject_digest))
    end

    private

    def transition(expected_digest, resolved:, authorize:)
      self.class.ensure_writable!(@company)
      result = @company.with_lock do
        self.class.ensure_writable!(@company)
        authorize&.call
        unless @user.payroll_access_allowed? && @user.can_access_company?(@company.id) && StaffRolePolicy.allowed?(@user, :review_payroll_history)
          raise Forbidden, "Payroll history review access required"
        end

        entry = Detector.new(company: @company, tax_year: @tax_year).call(apply: true, required_key: @subject_key)
          .fetch(:items).find { |_item, subject| subject.route_key == @subject_key }
        if entry && entry.first.subject_digest == expected_digest && entry.first.resolved? == resolved
          yield entry.first
          entry
        end
      end
      result || raise(Conflict, "Payroll history changed. Refresh and review the latest evidence.")
    end
  end
end
