# frozen_string_literal: true

class CreateEmployeeYearFicaSourceReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_year_fica_source_reviews do |t|
      t.references :company, null: false, foreign_key: true
      t.references :employee, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.integer :tax_year, null: false
      t.date :through_pay_date, null: false
      t.decimal :external_ss_wage_bound, precision: 15, scale: 2, null: false
      t.decimal :external_medicare_wage_bound, precision: 15, scale: 2, null: false
      t.string :review_reference, null: false
      t.timestamps
    end
    add_index :employee_year_fica_source_reviews, [ :employee_id, :tax_year, :id ], name: "idx_fica_source_reviews_employee_year"
    add_check_constraint :employee_year_fica_source_reviews,
      "external_ss_wage_bound >= 0 AND external_medicare_wage_bound >= external_ss_wage_bound AND external_medicare_wage_bound < 'Infinity'::numeric",
      name: "fica_source_review_bounds"
  end
end
