# frozen_string_literal: true

class AddCertificationEvidenceToEmployeeReviews < ActiveRecord::Migration[8.0]
  def up
    change_table :employee_configuration_review_resolutions, bulk: true do |t|
      t.string :source_reference
      t.date :effective_on
    end

    add_check_constraint :employee_configuration_review_resolutions,
                         "source_reference IS NULL OR char_length(source_reference) <= 255",
                         name: "employee_config_review_source_reference_length"
    add_check_constraint :employee_configuration_review_resolutions,
                         <<~SQL.squish,
                           item_code NOT IN (
                             'certify_employee_profile', 'certify_variable_salary_pay',
                             'certify_retirement_configuration', 'certify_multiple_wage_rates',
                             'certify_tipped_pay', 'certify_contractor_setup',
                             'loan_balance_not_transferred'
                           ) OR (
                             source_reference IS NOT NULL AND btrim(source_reference) <> '' AND effective_on IS NOT NULL
                           )
                         SQL
                         name: "employee_config_review_certification_evidence"

    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_employee_configuration_review_resolution_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'employee_configuration_review_resolutions are append-only';
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER employee_configuration_review_resolutions_append_only
      BEFORE UPDATE OR DELETE ON employee_configuration_review_resolutions
      FOR EACH ROW EXECUTE FUNCTION prevent_employee_configuration_review_resolution_mutation();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS employee_configuration_review_resolutions_append_only ON employee_configuration_review_resolutions"
    execute "DROP FUNCTION IF EXISTS prevent_employee_configuration_review_resolution_mutation()"

    remove_check_constraint :employee_configuration_review_resolutions,
                            name: "employee_config_review_certification_evidence",
                            if_exists: true
    remove_check_constraint :employee_configuration_review_resolutions,
                            name: "employee_config_review_source_reference_length",
                            if_exists: true

    change_table :employee_configuration_review_resolutions, bulk: true do |t|
      t.remove :source_reference, :effective_on
    end
  end
end
