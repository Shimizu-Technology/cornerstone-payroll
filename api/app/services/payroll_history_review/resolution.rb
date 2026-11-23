# frozen_string_literal: true

module PayrollHistoryReview
  class Resolution
    class Conflict < StandardError; end
    class Forbidden < StandardError; end

    def initialize(item:, user:, actor:)
      @item, @user, @actor = item, user, actor
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
        self.class.reopen_item!(item, reason: reason.strip, actor: @actor, digest: item.subject_digest)
      end
    end

    def self.reopen_item!(item, reason:, actor:, digest:)
      previous = item.attributes.slice(*PayrollHistoryReviewItem::RESOLUTION_FIELDS, "subject_digest")
      item.update!(PayrollHistoryReviewItem::RESOLUTION_FIELDS.index_with(nil).merge(
        status: "open", subject_digest: digest, reopened_at: Time.current))
      audit!(item, action: "reopen", actor: actor, metadata: { reason: reason, previous_resolution: previous })
    end

    def self.audit!(item, action:, actor:, metadata:)
      AuditLog.record!(actor: actor, organization_id: item.company.organization_id, company_id: item.company_id,
        action: "payroll_history_review##{action}", record_type: item.class.name, record_id: item.id,
        metadata: metadata.merge(tax_year: item.tax_year, subject_type: item.subject_type, subject_digest: item.subject_digest))
    end

    private

    def transition(expected_digest, resolved:, authorize:)
      company = @item.company
      result = company.with_lock do
        authorize&.call
        unless @user.payroll_access_allowed? && @user.can_access_company?(company.id) && StaffRolePolicy.allowed?(@user, :review_payroll_history)
          raise Forbidden, "Payroll history review access required"
        end

        entry = Detector.new(company: company, tax_year: @item.tax_year).call(apply: true, actor: @actor)
          .fetch(:items).find { |item, _subject| item.id == @item.id }
        if entry && entry.first.subject_digest == expected_digest && entry.first.resolved? == resolved
          yield entry.first
          entry
        end
      end
      result || raise(Conflict, "Payroll history changed. Refresh and review the latest evidence.")
    end
  end
end
