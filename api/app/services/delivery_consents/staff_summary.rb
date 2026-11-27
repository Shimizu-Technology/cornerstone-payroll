# frozen_string_literal: true

module DeliveryConsents
  # Simple read-only consent status summary for the staff employee record,
  # with how the company's active employees answered so staff know who still needs paper.
  class StaffSummary
    def self.for(employee)
      company = employee.company
      feature_enabled = CompanyFeatures.for(company).employee_portal_feature?(:delivery_consent)
      consents_by_kind = DeliveryConsent
        .includes(:delivery_disclosure)
        .where(company_id: employee.company_id, employee_id: employee.id)
        .order(given_at: :desc, id: :desc)
        .to_a
        .group_by(&:kind)
      preferences = DeliveryPreference
        .where(company_id: employee.company_id, employee_id: employee.id)
        .index_by(&:kind)

      items = DeliveryDisclosure::KINDS.map do |kind|
        records = consents_by_kind.fetch(kind, [])
        active = records.find(&:active?)
        latest = active || records.first
        withdrawn = records.find(&:withdrawn?)
        preference = preferences[kind]
        current_disclosure = DeliveryDisclosure.current_for(kind)
        readiness = ElectronicOnlyReadiness.evaluate(kind: kind, disclosure: current_disclosure)

        status = if active
          "consented"
        elsif latest&.withdrawn?
          "withdrawn"
        else
          "not_consented"
        end

        {
          kind: kind,
          status: status,
          answer: Answers.answer(active_consent: active, withdrawn_consent: withdrawn, preference: preference),
          paper_chosen_at: (Answers.paper_chosen_at(withdrawn_consent: withdrawn, preference: preference)&.iso8601 unless active),
          disclosure_version: latest&.disclosure_version,
          disclosure_status: latest&.delivery_disclosure&.status || current_disclosure&.status,
          given_at: latest&.given_at&.iso8601,
          withdrawn_at: active ? nil : latest&.withdrawn_at&.iso8601,
          method: latest&.method,
          electronic_only_ready: readiness.ready?,
          paper_continues: readiness.paper_required? || active.nil? || !active.matches_disclosure?(current_disclosure)
        }
      end

      {
        feature_enabled: feature_enabled,
        paper_delivery_continues: items.any? { |item| item[:paper_continues] },
        items: items,
        company_counts: Answers.company_counts(employee.company_id)
      }
    end
  end
end
