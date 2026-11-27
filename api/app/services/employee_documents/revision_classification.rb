# frozen_string_literal: true

module EmployeeDocuments
  module RevisionClassification
    module_function

    def compare(figures:, previous_figures:, predecessor:, same_item:, prior_label:)
      return { money_changed: false, ytd_changed: false, correction_label: false } unless predecessor

      money_changed = (figures.current != previous_figures.current) if figures && previous_figures
      structural = !same_item || predecessor.withdrawn? || predecessor.withdrawal_reason.present?
      {
        money_changed: money_changed,
        ytd_changed: same_item && money_changed == false && figures.full != previous_figures.full,
        correction_label: structural || prior_label || money_changed != false
      }
    end
  end
end
