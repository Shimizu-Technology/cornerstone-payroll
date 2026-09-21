# frozen_string_literal: true

class AllowAireOnboardingReviewSource < ActiveRecord::Migration[8.0]
  def up
    remove_check_constraint :employees, name: "employees_configuration_source_check"
    add_check_constraint :employees,
                         "configuration_source IS NULL OR configuration_source IN ('quickbooks_history', 'aire_onboarding')",
                         name: "employees_configuration_source_check"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "AIRE onboarding profiles may now exist"
  end
end
