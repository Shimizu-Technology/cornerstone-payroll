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

    # Per kind, how the company's active employees answered. The employees are
    # read once, so every kind counts the same people; 1099 contractors don't
    # get a W-2GU and are left out of its counts.
    def self.company_counts(company_id)
      employees = Employee.active.where(company_id: company_id).pluck(:id, :employment_type)
      ids = employees.map(&:first)
      consents = DeliveryConsent.where(company_id: company_id, employee_id: ids).pluck(:kind, :employee_id, :withdrawn_at)
      preferences = DeliveryPreference.where(company_id: company_id, employee_id: ids).pluck(:kind, :employee_id)

      DeliveryDisclosure::KINDS.index_with do |kind|
        counted = employees.reject { |_id, type| kind == "w2gu" && type == "contractor" }.to_set(&:first)
        of_kind = consents.select { |row| row[0] == kind && counted.include?(row[1]) }
        paperless = of_kind.select { |row| row[2].nil? }.to_set { |row| row[1] }
        paper = (of_kind.reject { |row| row[2].nil? }.map { |row| row[1] } +
          preferences.select { |row| row[0] == kind && counted.include?(row[1]) }.map { |row| row[1] }).to_set - paperless

        {
          paperless: paperless.size,
          keep_paper: paper.size,
          not_answered: counted.size - paperless.size - paper.size,
          total: counted.size
        }
      end
    end
  end
end
