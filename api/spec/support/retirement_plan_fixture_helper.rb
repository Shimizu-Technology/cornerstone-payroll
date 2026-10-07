# frozen_string_literal: true

module RetirementPlanFixtureHelper
  # Opt-in evidence for scenarios explicitly testing a verified synthetic plan.
  # Unknown-plan regression tests deliberately do not call this helper.
  def verify_synthetic_retirement_plan!(employee, pay_date, **overrides)
    traditional_match = employee.employer_retirement_match_rate.to_d
    roth_match = employee.employer_roth_match_rate.to_d
    destination = traditional_match.positive? ? "traditional" : "roth"
    rate = traditional_match.positive? ? traditional_match : roth_match
    if traditional_match.positive? && roth_match.positive?
      type = employee.company.deduction_types.create!(name: "Synthetic verified Roth employer contribution",
        category: "employer_contribution", sub_category: "retirement", reporting_group: "401k_after_tax")
      employee.employee_deductions.create!(deduction_type: type, amount: roth_match * 100,
        is_percentage: true, active: true)
    end
    employee.employee_retirement_elections.create!({
      company: employee.company, effective_on: pay_date, participating: true,
      traditional_rate: employee.retirement_rate, roth_rate: employee.roth_retirement_rate,
      roth_available: true, employer_roth_available: true,
      employer_match_mode: rate.positive? ? "compensation_percentage" : "none",
      employer_match_rate: rate, employer_match_destination: destination,
      plan_source_reference: "Synthetic verified plan and provider reporting confirmation",
      source: "staff", reason: "Verified test plan evidence"
    }.merge(overrides))
  end
end

RSpec.configure do |config|
  config.include RetirementPlanFixtureHelper
end
