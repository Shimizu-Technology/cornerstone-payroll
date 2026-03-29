class FixEmployerContributionDeductionTypeCategories < ActiveRecord::Migration[8.0]
  MATCH_LABELS = [
    "401(k) Employer Match",
    "Roth 401(k) Employer Match"
  ].freeze

  def up
    DeductionType
      .where(name: MATCH_LABELS, sub_category: "retirement", category: "pre_tax")
      .update_all(category: "employer_contribution")
  end

  def down
    DeductionType
      .where(name: MATCH_LABELS, sub_category: "retirement", category: "employer_contribution")
      .update_all(category: "pre_tax")
  end
end
