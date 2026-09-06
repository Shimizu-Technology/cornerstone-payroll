# frozen_string_literal: true

class ValidateEmployeeConfigurationConstraints < ActiveRecord::Migration[8.0]
  def change
    validate_check_constraint :employees, name: "employees_configuration_review_status_check"
    validate_check_constraint :employees, name: "employees_configuration_source_check"
    validate_check_constraint :employees, name: "employees_configuration_review_items_array"
  end
end
