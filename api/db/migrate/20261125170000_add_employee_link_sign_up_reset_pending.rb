# frozen_string_literal: true

# M4-2 review: a sign-up reset runs in phases around Clerk. While one is
# pending, the link's old sign-up can't bind or restart, and staff can run
# the reset again to finish it. Additive only; the table is empty in
# production and already covered by row-level security.
class AddEmployeeLinkSignUpResetPending < ActiveRecord::Migration[8.1]
  def change
    change_table :employee_account_links, bulk: true do |t|
      t.datetime :sign_up_reset_requested_at
      t.references :sign_up_reset_requested_by, foreign_key: { to_table: :users }
      t.string :sign_up_reset_reason, limit: 500
    end

    add_check_constraint :employee_account_links,
      "(sign_up_reset_requested_at IS NULL) = (sign_up_reset_reason IS NULL)",
      name: "employee_account_links_sign_up_reset_check"
  end
end
