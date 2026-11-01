# frozen_string_literal: true

class TrackSharedPayrollReviews < ActiveRecord::Migration[8.1]
  def up
    add_column :payroll_review_packages, :sent_for_client_approval_at, :datetime
    add_column :payroll_review_packages, :client_review_history_unknown, :boolean, default: true, null: false
    # Historical settings changes were not recorded with their values. Keep
    # old revisions whose sharing history cannot be proved. Only current visible revisions
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
    # The database boundary also covers older application processes during
    # rolling deployment: model callbacks alone cannot record their writes.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION retain_published_payroll_reviews()
      RETURNS trigger AS $$
      BEGIN
        IF OLD.client_payroll_approval_required OR NEW.client_payroll_approval_required THEN
          UPDATE payroll_review_packages AS review
          SET sent_for_client_approval_at = COALESCE(review.sent_for_client_approval_at, CURRENT_TIMESTAMP),
              client_review_history_unknown = FALSE
          FROM pay_periods
          WHERE review.company_id = NEW.id
            AND review.pay_period_id = pay_periods.id
            AND review.superseded_at IS NULL
            AND pay_periods.status IN ('calculated', 'approved');
        END IF;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;

      DROP TRIGGER IF EXISTS companies_retain_published_payroll_reviews ON companies;
      CREATE TRIGGER companies_retain_published_payroll_reviews
      BEFORE UPDATE OF client_payroll_approval_required ON companies
      FOR EACH ROW
      EXECUTE FUNCTION retain_published_payroll_reviews();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS companies_retain_published_payroll_reviews ON companies"
    execute "DROP FUNCTION IF EXISTS retain_published_payroll_reviews()"
    remove_column :payroll_review_packages, :client_review_history_unknown
    remove_column :payroll_review_packages, :sent_for_client_approval_at
  end
end
