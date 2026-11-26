# frozen_string_literal: true

class ValidateCornerstonePayrollReviewOverride < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '5s'"
    %w[approval_method_check approval_shape].each do |suffix|
      validate_check_constraint :payroll_review_packages, name: "payroll_review_packages_#{suffix}"
    end
  end

  def down
    # The validated constraints still apply until the preceding migration.
  end
end
