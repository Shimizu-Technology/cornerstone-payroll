# frozen_string_literal: true

class TrackSharedPayrollReviews < ActiveRecord::Migration[8.1]
  def up
    add_column :payroll_review_packages, :sent_for_client_approval_at, :datetime
    # Required client reviews are published in the portal on calculation, with
    # no separate send endpoint. Retain existing published revisions too.
    execute <<~SQL
      UPDATE payroll_review_packages AS review
      SET sent_for_client_approval_at = review.generated_at
      FROM companies
      WHERE review.company_id = companies.id
        AND companies.client_payroll_approval_required = TRUE
    SQL
  end

  def down
    remove_column :payroll_review_packages, :sent_for_client_approval_at
  end
end
