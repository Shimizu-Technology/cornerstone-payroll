# frozen_string_literal: true

module DeliveryConsents
  # Builds the employee-facing electronic delivery consent status payload.
  # Regular employees see disclosure text plainly without draft markers;
  # staff members and development environments see a small "Draft wording" marker
  # when a disclosure's status is "draft".
  class StatusPresenter
    def initialize(employee:, company:, user:)
      @employee = employee
      @company = company
      @user = user
    end

    def as_json(*)
      consents_by_kind = DeliveryConsent
        .where(company_id: @company.id, employee_id: @employee.id)
        .order(given_at: :desc, id: :desc)
        .to_a
        .group_by(&:kind)

      items = DeliveryDisclosure::KINDS.map do |kind|
        build_item(kind, consents_by_kind.fetch(kind, []))
      end

      {
        paper_delivery_continues: items.any? { |item| item[:paper_continues] },
        consents: items
      }
    end

    private

    def show_draft_marker_for?(disclosure)
      disclosure.draft? && (@user&.staff_member? == true || Rails.env.development?)
    end

    def build_item(kind, records)
      disclosure = DeliveryDisclosure.current_for(kind)
      active_consent = records.find(&:active?)
      last_withdrawn = records.find(&:withdrawn?)
      readiness = ElectronicOnlyReadiness.evaluate(kind: kind, disclosure: disclosure)
      paper_continues = readiness.paper_required? || active_consent.nil? || !active_consent.matches_disclosure?(disclosure)

      status = if active_consent
        "consented"
      elsif last_withdrawn
        "withdrawn"
      else
        "not_consented"
      end

      {
        kind: kind,
        status: status,
        active_consent: serialize_active_consent(active_consent, disclosure),
        last_withdrawn_at: last_withdrawn&.withdrawn_at&.iso8601,
        disclosure: serialize_disclosure(disclosure),
        requires_access_proof: kind == "w2gu",
        email_notice_locked_on: kind == "w2gu" && active_consent.present?,
        paper_continues: paper_continues,
        electronic_only_ready: readiness.ready?
      }
    end

    def serialize_active_consent(consent, disclosure)
      return nil unless consent

      {
        id: consent.id,
        disclosure_version: consent.disclosure_version,
        disclosure_digest: consent.disclosure_digest,
        given_at: consent.given_at.iso8601,
        method: consent.method,
        matches_current_disclosure: consent.matches_disclosure?(disclosure)
      }
    end

    def serialize_disclosure(disclosure)
      return nil unless disclosure

      {
        version: disclosure.version,
        title: disclosure.title,
        text: disclosure.text,
        digest: disclosure.digest,
        published_at: disclosure.published_at&.iso8601,
        draft_marker: show_draft_marker_for?(disclosure)
      }
    end
  end
end
