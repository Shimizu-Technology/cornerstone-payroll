class AddPracticeCompanyToUsers < ActiveRecord::Migration[8.0]
  def change
    add_reference :users, :practice_company, foreign_key: { to_table: :companies }, index: true
    add_check_constraint :users, "practice_company_id IS NULL OR (company_id = practice_company_id AND role = 4)", name: "users_practice_scope"
  end
end
