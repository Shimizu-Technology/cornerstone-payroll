# frozen_string_literal: true

class TrackSharedPayrollReviews < ActiveRecord::Migration[8.1]
  def up
    add_column :payroll_review_packages, :sent_for_client_approval_at, :datetime
    add_column :payroll_review_packages, :client_review_history_unknown, :boolean, default: true, null: false
    # Historical settings changes were not recorded with their values. Keep
    # old revisions whose sharing history cannot be proved; new automatic
    # revisions start with known visibility. Only current visible revisions
    # can be positively identified as shared at this migration boundary.
    execute <<~SQL
      UPDATE payroll_review_packages AS review
      SET client_review_history_unknown = TRUE
    SQL
    execute <<~SQL
      UPDATE payroll_review_packages AS review
      SET sent_for_client_approval_at = CURRENT_TIMESTAMP, client_review_history_unknown = FALSE
      FROM companies, pay_periods
      WHERE review.company_id = companies.id
        AND review.pay_period_id = pay_periods.id
        AND companies.client_payroll_approval_required = TRUE
        AND review.superseded_at IS NULL
        AND pay_periods.status IN ('calculated', 'approved')
    SQL
  end

  def down
    remove_column :payroll_review_packages, :client_review_history_unknown
    remove_column :payroll_review_packages, :sent_for_client_approval_at
  end
end
