# frozen_string_literal: true

class AddCompanySetupReviewerSnapshots < ActiveRecord::Migration[8.0]
  def up
    add_column :payroll_go_live_reviews, :company_setup_reviewed_by_name, :string
    add_column :payroll_go_live_reviews, :company_setup_reviewed_by_email, :string
    add_column :payroll_go_live_reviews, :company_setup_reviewed_by_role, :string

    execute <<~SQL.squish
      UPDATE payroll_go_live_reviews AS reviews
      SET company_setup_reviewed_by_name = users.name,
          company_setup_reviewed_by_email = users.email,
          company_setup_reviewed_by_role = CASE users.role
            WHEN 0 THEN 'admin'
            WHEN 1 THEN 'manager'
            WHEN 2 THEN 'employee'
            WHEN 3 THEN 'accountant'
            WHEN 4 THEN 'client'
            WHEN 5 THEN 'super_admin'
            WHEN 6 THEN 'org_admin'
            ELSE users.role::text
          END
      FROM users
      WHERE reviews.company_setup_reviewed_by_id = users.id
        AND reviews.company_setup_digest IS NOT NULL
    SQL
  end

  def down
    remove_column :payroll_go_live_reviews, :company_setup_reviewed_by_role
    remove_column :payroll_go_live_reviews, :company_setup_reviewed_by_email
    remove_column :payroll_go_live_reviews, :company_setup_reviewed_by_name
  end
end
