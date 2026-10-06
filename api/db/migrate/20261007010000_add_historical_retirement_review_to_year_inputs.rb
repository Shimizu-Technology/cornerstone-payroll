class AddHistoricalRetirementReviewToYearInputs < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_retirement_year_inputs, :historical_retirement_review, :jsonb, null: false, default: {}
    add_check_constraint :employee_retirement_year_inputs,
      "jsonb_typeof(historical_retirement_review) = 'object'", name: "retirement_year_inputs_review_object"
  end
end
