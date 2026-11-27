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

    # Per employee and kind, { answer:, answered_at: } for employees of one company.
    def self.by_employee(company_id, employee_ids)
      ids = employee_ids.to_a
      consents = DeliveryConsent.where(company_id: company_id, employee_id: ids)
        .order(given_at: :desc, id: :desc).to_a.group_by { |consent| [ consent.employee_id, consent.kind ] }
      preferences = DeliveryPreference.where(company_id: company_id, employee_id: ids)
        .index_by { |preference| [ preference.employee_id, preference.kind ] }

      ids.index_with do |employee_id|
        DeliveryDisclosure::KINDS.index_with do |kind|
          records = consents.fetch([ employee_id, kind ], [])
          active = records.find(&:active?)
          withdrawn = records.find(&:withdrawn?)
          preference = preferences[[ employee_id, kind ]]
          {
            answer: answer(active_consent: active, withdrawn_consent: withdrawn, preference: preference),
            answered_at: active ? active.given_at : paper_chosen_at(withdrawn_consent: withdrawn, preference: preference)
          }
        end
      end
    end

    # Per kind, how the company's active employees answered.
    def self.company_counts(company_id)
      answers = by_employee(company_id, Employee.active.where(company_id: company_id).pluck(:id)).values

      DeliveryDisclosure::KINDS.index_with do |kind|
        tally = answers.map { |row| row.dig(kind, :answer) }.tally
        {
          paperless: tally.fetch(PAPERLESS, 0),
          keep_paper: tally.fetch(KEEP_PAPER, 0),
          not_answered: tally.fetch(NOT_ANSWERED, 0),
          total: answers.size
        }
      end
    end
  end
end
