# frozen_string_literal: true

class ProtectEmployeeYearFicaSourceReviews < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE OR REPLACE FUNCTION prevent_fica_source_review_mutation()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'employee_year_fica_source_reviews are append-only';
      END;
      $$ LANGUAGE plpgsql;
      DROP TRIGGER IF EXISTS fica_source_reviews_append_only ON employee_year_fica_source_reviews;
      CREATE TRIGGER fica_source_reviews_append_only
      BEFORE UPDATE OR DELETE ON employee_year_fica_source_reviews
      FOR EACH ROW EXECUTE FUNCTION prevent_fica_source_review_mutation();
      DROP TRIGGER IF EXISTS fica_source_reviews_no_truncate ON employee_year_fica_source_reviews;
      CREATE TRIGGER fica_source_reviews_no_truncate BEFORE TRUNCATE ON employee_year_fica_source_reviews
      FOR EACH STATEMENT EXECUTE FUNCTION prevent_fica_source_review_mutation();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS fica_source_reviews_no_truncate ON employee_year_fica_source_reviews"
    execute "DROP TRIGGER IF EXISTS fica_source_reviews_append_only ON employee_year_fica_source_reviews"
    execute "DROP FUNCTION IF EXISTS prevent_fica_source_review_mutation()"
  end
end
