class FixEmployerContributionDeductionTypeCategories < ActiveRecord::Migration[8.0]
  MATCH_LABELS = [
    "401(k) Employer Match",
    "Roth 401(k) Employer Match"
  ].freeze

  def up
    DeductionType
      .left_outer_joins(:employee_deductions)
      .where(name: MATCH_LABELS, sub_category: "retirement", category: "pre_tax")
      .where(employee_deductions: { id: nil })
      .update_all(category: "employer_contribution")
  end

  def down
    DeductionType
      .left_outer_joins(:employee_deductions)
      .where(name: MATCH_LABELS, sub_category: "retirement", category: "employer_contribution")
      .where(employee_deductions: { id: nil })
      .update_all(category: "pre_tax")
  end
end
