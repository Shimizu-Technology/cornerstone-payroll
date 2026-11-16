# frozen_string_literal: true

class AddPayrollReviewChangeRequests < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_review_packages, :published_at, :datetime
    reversible do |direction|
      direction.up do
        execute <<~SQL
          UPDATE payroll_review_packages review
          SET published_at = review.sent_for_client_approval_at
          FROM pay_periods period
          WHERE period.id = review.pay_period_id AND period.status = 'approved'
            AND review.superseded_at IS NULL
        SQL
      end
    end
    add_reference :payroll_review_packages, :changes_requested_by, foreign_key: { to_table: :users }
    add_column :payroll_review_packages, :changes_requested_at, :datetime
    add_column :payroll_review_packages, :change_request_note, :text
    add_check_constraint :payroll_review_packages,
      "(changes_requested_at IS NULL AND changes_requested_by_id IS NULL AND change_request_note IS NULL) OR " \
      "(changes_requested_at IS NOT NULL AND changes_requested_by_id IS NOT NULL AND NULLIF(BTRIM(change_request_note), '') IS NOT NULL AND LENGTH(change_request_note) <= 2000 AND status <> 'approved')",
      name: "payroll_review_change_request_shape"
  end
end
