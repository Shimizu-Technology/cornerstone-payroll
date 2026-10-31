# frozen_string_literal: true

# Translate known, fail-closed history checks at calculation boundaries only.
# Financial posting and the strict component readers keep their original errors.
class PayrollCalculationHistory
  class HoldError < ArgumentError; end

  ERRORS = [ PayrollComponentMirrors::AmbiguousHistoryError,
    PayrollInsuranceComponents::AmbiguousHistoryError,
    PayrollRetirementCatchUp::UnprovedHistoryError ].freeze

  def self.message(error)
    if error.is_a?(PayrollRetirementCatchUp::UnprovedHistoryError)
      "Retirement history for this employee needs review before payroll can be calculated. Ask an administrator or accountant to arrange a reviewed annual retirement reconciliation."
    else
      "Benefit history for this employee needs review before payroll can be calculated. Ask an administrator or accountant to reconcile the saved benefit records."
    end
  end
end
