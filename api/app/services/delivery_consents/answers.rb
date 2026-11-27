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
    # Each source is reduced to one row per employee and kind in SQL: the active
    # consent (unique), the latest withdrawal, and the keep-paper answer (unique).
    def self.by_employee(company_id, employee_ids)
      ids = employee_ids.to_a
      key = ->(employee_id, kind) { [ employee_id, kind ] }
      active = DeliveryConsent.active.where(company_id: company_id, employee_id: ids)
        .pluck(:employee_id, :kind, :given_at).to_h { |employee_id, kind, at| [ key.(employee_id, kind), at ] }
      withdrawn = DeliveryConsent.withdrawn.where(company_id: company_id, employee_id: ids)
        .select("DISTINCT ON (employee_id, kind) employee_id, kind, withdrawn_at")
        .reorder(:employee_id, :kind, withdrawn_at: :desc, id: :desc)
        .to_h { |consent| [ key.(consent.employee_id, consent.kind), consent.withdrawn_at ] }
      preferences = DeliveryPreference.where(company_id: company_id, employee_id: ids)
        .pluck(:employee_id, :kind, :recorded_at).to_h { |employee_id, kind, at| [ key.(employee_id, kind), at ] }

      ids.index_with do |employee_id|
        DeliveryDisclosure::KINDS.index_with do |kind|
          given_at = active[key.(employee_id, kind)]
          withdrawn_at = withdrawn[key.(employee_id, kind)]
          recorded_at = preferences[key.(employee_id, kind)]
          {
            answer: answer(active_consent: given_at, withdrawn_consent: withdrawn_at, preference: recorded_at),
            answered_at: given_at || [ withdrawn_at, recorded_at ].compact.max
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
