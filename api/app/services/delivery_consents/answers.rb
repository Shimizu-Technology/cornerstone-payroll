# frozen_string_literal: true

module DeliveryConsents
  # The employee's answer to "Go paperless?" for one delivery kind. An active
  # consent always wins; a withdrawal or an explicit DeliveryPreference counts
  # as "keep paper"; anything else is unanswered. The answer is informational:
  # paper delivery still follows ElectronicOnlyReadiness, never this.
  module Answers
    PAPERLESS = "paperless"
    KEEP_PAPER = "keep_paper"
    NOT_ANSWERED = "not_answered"

    def self.answer(active_consent:, withdrawn_consent:, preference:)
      return PAPERLESS if active_consent
      return KEEP_PAPER if withdrawn_consent || preference

      NOT_ANSWERED
    end

    # When the employee chose paper: the explicit answer, else the latest withdrawal.
    def self.paper_chosen_at(withdrawn_consent:, preference:)
      [ preference&.recorded_at, withdrawn_consent&.withdrawn_at ].compact.max
    end

    # Per kind, how the company's active employees answered.
    def self.company_counts(company_id)
      employees = Employee.active.where(company_id: company_id)
      total = employees.count
      consents = DeliveryConsent.where(company_id: company_id, employee_id: employees.select(:id))
        .pluck(:kind, :employee_id, :withdrawn_at)
      preferences = DeliveryPreference.where(company_id: company_id, employee_id: employees.select(:id))
        .pluck(:kind, :employee_id)

      DeliveryDisclosure::KINDS.index_with do |kind|
        of_kind = consents.select { |row| row[0] == kind }
        paperless = of_kind.select { |row| row[2].nil? }.to_set { |row| row[1] }
        paper = (of_kind.reject { |row| row[2].nil? }.map { |row| row[1] } +
          preferences.select { |row| row[0] == kind }.map { |row| row[1] }).to_set - paperless

        {
          paperless: paperless.size,
          keep_paper: paper.size,
          not_answered: total - paperless.size - paper.size,
          total: total
        }
      end
    end
  end
end
